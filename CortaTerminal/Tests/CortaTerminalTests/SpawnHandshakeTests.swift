// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import CortaTerminal

/// The `corta-exec` handshake: bounded, `EINTR`-tolerant, fully
/// decoded. The pipe tests drive `readHelperStatus` directly; the last
/// three spawn real children (hence `.serialized`).
@Suite(.serialized) struct SpawnHandshakeTests {
    /// #545: the bundle is the **last** `.app/Contents/` in the image path,
    /// not the first. A build kept inside another application's bundle, or
    /// under a folder whose name ends in `.app`, still finds its own
    /// `corta-exec`; the hosted test bundle under `Contents/PlugIns` resolves
    /// to the app that hosts it.
    @Test("inside an app bundle the helper is looked for in one place only")
    func insideABundleTheHelperHasOneCandidate() {
        let cases: [(image: String, helper: String)] = [
            (
                "/Applications/Corta.app/Contents/MacOS/Corta",
                "/Applications/Corta.app/Contents/MacOS/corta-exec"
            ),
            (
                "/Applications/Corta.app/Contents/Frameworks/"
                    + "CortaTerminal.framework/Versions/A/CortaTerminal",
                "/Applications/Corta.app/Contents/MacOS/corta-exec"
            ),
            (
                "/Applications/Corta Dev.app/Contents/PlugIns/"
                    + "CortaTests.xctest/Contents/MacOS/CortaTests",
                "/Applications/Corta Dev.app/Contents/MacOS/corta-exec"
            ),
            (
                "/Applications/Outer.app/Contents/Resources/Corta.app/Contents/MacOS/Corta",
                "/Applications/Outer.app/Contents/Resources/Corta.app/Contents/MacOS/corta-exec"
            ),
            (
                "/Users/someone/Something.app/Corta.app/Contents/MacOS/Corta",
                "/Users/someone/Something.app/Corta.app/Contents/MacOS/corta-exec"
            ),
        ]
        for (image, helper) in cases {
            #expect(
                Spawn.helperCandidates(forImage: image) == [helper],
                "\(image) should resolve to its own bundle's helper")
        }
    }

    @Test("outside a bundle the helper is found beside a SwiftPM build, at most six levels up")
    func outsideABundleTheWalkIsBounded() {
        let candidates = Spawn.helperCandidates(
            forImage: "/r/.build/debug/CortaTerminalPackageTests.xctest/Contents/MacOS/CortaTerminalPackageTests")
        #expect(candidates.contains("/r/.build/debug/corta-exec"))
        #expect(candidates.first == "/r/.build/debug/CortaTerminalPackageTests.xctest/Contents/MacOS/corta-exec")
        let deep = Spawn.helperCandidates(forImage: "/1/2/3/4/5/6/7/8/image")
        #expect(deep.count == 6 && deep.last == "/1/2/3/corta-exec")
    }

    @Test func decodesAFullErrnoStatus() throws {
        let ends = try makePipe()
        defer { close(ends.read) }

        var code: Int32 = ENOENT
        withUnsafeBytes(of: &code) { bytes in
            #expect(Darwin.write(ends.write, bytes.baseAddress, bytes.count) == bytes.count)
        }
        close(ends.write)

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: SuspendingClock.now + .seconds(5))
        #expect(status == .execFailed(code: ENOENT))
    }

    @Test func cleanEOFSignalsExecSuccess() throws {
        let ends = try makePipe()
        defer { close(ends.read) }
        close(ends.write)  // FD_CLOEXEC closing on a successful execve

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: SuspendingClock.now + .seconds(5))
        #expect(status == .execSucceeded)
    }

    @Test func truncatedStatusIsReported() throws {
        let ends = try makePipe()
        defer { close(ends.read) }

        var partial: (UInt8, UInt8) = (0x02, 0x00)
        withUnsafeBytes(of: &partial) { bytes in
            #expect(Darwin.write(ends.write, bytes.baseAddress, bytes.count) == bytes.count)
        }
        close(ends.write)

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: SuspendingClock.now + .seconds(5))
        #expect(status == .truncated)
    }

    @Test func stalledHelperHitsTheDeadlineInsteadOfBlocking() throws {
        let ends = try makePipe()
        // The write end stays open past the deadline, as a wedged helper
        // would leave it.
        defer { close(ends.write) }
        defer { close(ends.read) }

        let deadline = SuspendingClock.now + .milliseconds(200)
        let status = Spawn.readHelperStatus(from: ends.read, deadline: deadline)
        #expect(status == .timedOut)
        #expect(SuspendingClock.now < deadline + .seconds(5))
    }

    @Test func failedExecReportsTheHelpersErrno() throws {
        // End to end: `corta-exec` fails the execve, writes ENOENT, and
        // `Spawn.child` throws it (and reaps the helper).
        #expect(throws: PTYError.spawnFailed(code: ENOENT)) {
            try PTY.spawn(executable: "/nonexistent/corta-does-not-exist")
        }
    }

    /// The working directory is a `posix_spawn` file action: the child —
    /// and so the shell `corta-exec` execs — starts there.
    @Test func theChildStartsInTheWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // `realpath`, not `resolvingSymlinksInPath`, which drops `/private`.
        let resolved = try #require(realpath(directory.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let exited = DispatchSemaphore(value: 0)
        let pty = try PTY.spawn(
            executable: "/bin/sh", arguments: ["-c", "pwd -P > out"],
            workingDirectory: resolved, terminationHandler: { _ in exited.signal() })
        #expect(exited.wait(timeout: .now() + 10) == .success)
        _ = pty
        let written = try String(contentsOfFile: resolved + "/out", encoding: .utf8)
        #expect(written.trimmingCharacters(in: .newlines) == resolved)
    }

    /// A directory that is gone fails the spawn with `chdir`'s errno, rather
    /// than starting the shell somewhere else.
    @Test func aMissingWorkingDirectoryFailsTheSpawn() {
        #expect(throws: PTYError.spawnFailed(code: ENOENT)) {
            try PTY.spawn(
                executable: "/bin/sh", arguments: ["-c", "true"],
                workingDirectory: "/nonexistent/corta-no-such-directory")
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            Issue.record("pipe() failed: errno \(errno)")
            throw PTYError.openFailed(code: errno)
        }
        return (fds[0], fds[1])
    }
}
