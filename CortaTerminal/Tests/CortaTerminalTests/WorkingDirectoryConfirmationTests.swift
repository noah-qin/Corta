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

import Foundation
import Testing

@testable import CortaTerminal

/// A local OSC 7 report is believed only where the kernel agrees a local
/// process stands. Output — `cat` of a file, a remote shell sending no host —
/// can name any directory, and the local working directory feeds spawns,
/// restore and directory history.
@Suite(.serialized) struct WorkingDirectoryConfirmationTests {
    @Test("macOS's /private links compare equal; other paths do not")
    func samePlace() {
        #expect(PTY.isSamePlace("/tmp/x", kernel: "/private/tmp/x"))
        #expect(PTY.isSamePlace("/var/folders/a/T/", kernel: "/private/var/folders/a/T"))
        #expect(PTY.isSamePlace("/Users/me/src", kernel: "/Users/me/src"))
        #expect(PTY.isSamePlace("/", kernel: "/"))
        #expect(!PTY.isSamePlace("/Users/me/evil", kernel: "/Users/me/src"))
        #expect(!PTY.isSamePlace("/Users/me", kernel: "/Users/me/src"))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForReady(_ session: TerminalSession) -> Bool {
        let deadline = ContinuousClock.now + testTimeout(30)
        while ContinuousClock.now < deadline {
            if session.snapshot().dump().contains("READY") { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    @Test("a report of where the shell is stands")
    func trueReportStands() throws {
        let start = try directory()
        defer { try? FileManager.default.removeItem(at: start) }
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033]7;file://\(start.path)\\007READY\\n'; sleep 30"],
            workingDirectory: start.path)
        defer { session.stop() }
        session.start()
        #expect(waitForReady(session))
        #expect(session.workingDirectory == start.path)
    }

    @Test("a report of somewhere the shell is not falls back to the kernel's answer")
    func forgedReportFallsBack() throws {
        let start = try directory()
        let elsewhere = try directory()
        defer {
            try? FileManager.default.removeItem(at: start)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        // What a remote shell, or a file being `cat`ed, can send: an empty
        // host, which reads as this machine.
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033]7;file://\(elsewhere.path)\\007READY\\n'; sleep 30"],
            workingDirectory: start.path)
        defer { session.stop() }
        session.start()
        #expect(waitForReady(session))
        let directory = try #require(session.workingDirectory)
        #expect(directory != elsewhere.path)
        #expect(directory.hasSuffix(start.lastPathComponent))
        #expect(session.currentDirectory?.hasSuffix(start.lastPathComponent) == true)
    }
}
