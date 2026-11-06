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

import CortaSFTP
import CortaTerminal
import Darwin
import Foundation
import Testing

@testable import Corta

/// What the app's children hold of its descriptors (`SECURITY.md` §4.3), each
/// through the spawn it really uses, with a probe standing where the program
/// would. `DescriptorHygieneTests` holds a shell to the same rule.
@Suite("Child descriptors", .serialized)
struct ChildDescriptorTests {
    /// A valid header is all `decodePNG` looks at before it spawns.
    private static let png: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1,
    ]

    /// Writes the descriptors from 3 to 200 this process holds to `report`.
    /// A duplicate onto an unused number rather than `-e /dev/fd/n`, which
    /// cannot stat a shared-memory object: the pixel mapping would pass unseen,
    /// and so would a leaked one. Redirecting a number that is open (0, or 2 per
    /// command) makes bash park the old one on 10, which then reads as held.
    private static func probe(report: String) -> String {
        """
        exec 2>/dev/null; open=; n=3
        while [ $n -le 200 ]; do ( exec 222<&$n ) && open="$open $n"; n=$((n + 1)); done
        echo "open:$open" > '\(report)'
        """
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-fds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func executable(_ url: URL, _ script: String) throws {
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A descriptor open without close-on-exec, the shape of a leak, for the
    /// length of `body`.
    private func withOpenPipe(_ body: () throws -> Void) throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer {
            close(ends[0])
            close(ends[1])
        }
        #expect(ends[1] <= 200, "the probe does not reach descriptor \(ends[1])")
        try body()
    }

    private func awaitReport(_ url: URL) -> String? {
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while SuspendingClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") {
                return text.trimmingCharacters(in: .newlines)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    @Test("the image decoder gets its pipes and the pixel mapping, and nothing else")
    func decoderHoldsOnlyWhatItIsGiven() throws {
        try withScratch { folder in
            try withOpenPipe {
                let report = folder.appendingPathComponent("report")
                let helper = folder.appendingPathComponent("helper")
                try executable(helper, Self.probe(report: report.path))
                #expect(ImageDecoderProcess.decodePNG(Self.png, helper: helper.path) == nil)
                let held = awaitReport(report)
                #expect(held == "open: 3", "the decoder held \(held ?? "no report")")
            }
        }
    }

    @Test("a decoder that dies of its own alarm is an ordinary failed decode")
    func decoderDeadOfItsAlarmFailsCleanly() throws {
        try withScratch { folder in
            let helper = folder.appendingPathComponent("helper")
            try executable(helper, "kill -ALRM $$")
            #expect(ImageDecoderProcess.decodePNG(Self.png, helper: helper.path) == nil)
        }
    }

    /// Standing where `ssh` stands, with the broker listening, and running
    /// `SSH_ASKPASS` as `ssh` would. The real askpass client (Corta's own
    /// executable) spawns nothing, so what it could pass on stops with it.
    @Test("neither ssh nor the askpass it runs holds the broker's socket or anything else of ours")
    func sshAndAskpassHoldOnlyTheirStandardPipes() throws {
        try withScratch { folder in
            try withOpenPipe {
                let broker = SSHAskpassBroker(executable: Bundle.main.executablePath) { _ in nil }
                defer { broker.stop() }
                let grant = try #require(broker.grant(host: "probe"))
                let sshReport = folder.appendingPathComponent("ssh")
                let askpassReport = folder.appendingPathComponent("askpass")
                let askpass = folder.appendingPathComponent("askpass-probe")
                try executable(askpass, Self.probe(report: askpassReport.path))

                var environment = grant.environment
                environment["SSH_ASKPASS"] = askpass.path
                let script = Self.probe(report: sshReport.path) + "\n\"$SSH_ASKPASS\""
                let channel = try SFTPSubprocessChannel.spawn(
                    host: "probe", executable: "/bin/sh", arguments: ["-c", script], environment: environment)
                defer { channel.close() }
                #expect(awaitReport(sshReport) == "open:")
                #expect(awaitReport(askpassReport) == "open:")
            }
        }
    }
}

/// The decoder's own deadline (`corta-image-decoder`), on the real signed
/// helper under its real sandbox: nothing here can stand in for either.
@Suite("Image decoder deadline")
struct ImageDecoderDeadlineTests {
    /// The stuck decode this stands for has lost its parent, so nothing kills
    /// it: stdin stays open, and only the helper's alarm can end it. Longer
    /// than the app's own deadline, which stays the one that normally fires.
    @Test("an orphaned decoder ends itself on SIGALRM, after the app's deadline")
    func orphanedDecoderEndsItself() async throws {
        let helper = try #require(ImageDecoderProcess.bundledHelper)
        let pixels = try #require(ImageDecoderProcess.SharedPixels(width: 1, height: 1, alignment: 256))
        var input: [Int32] = [-1, -1]
        try #require(pipe(&input) == 0)
        defer {
            close(input[0])
            close(input[1])
        }
        _ = fcntl(input[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pixels.descriptor, 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
        defer { free(argv[0]) }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        try #require(posix_spawn(&pid, helper, &actions, &attributes, argv, envp) == 0)

        let started = SuspendingClock.now
        let ceiling = started + .seconds(25) * testTimeoutScale
        var status: Int32 = 0
        var reaped = false
        while SuspendingClock.now < ceiling {
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !reaped {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        #expect(reaped, "the decoder was still running with its stdin open")
        #expect(status & 0x7F == SIGALRM, "wait status \(status)")
        #expect(SuspendingClock.now - started > ImageDecoderProcess.timeout)
    }
}
