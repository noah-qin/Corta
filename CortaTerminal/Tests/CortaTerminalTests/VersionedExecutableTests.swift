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

/// Claude Code's native installer runs `…/claude/versions/2.1.316`, whose
/// kernel name is "2.1.316": the title, the tab and its icon read the tool.
@Suite("Versioned executables", .serialized)
struct VersionedExecutableTests {
    @Test func versionShapes() {
        for name in ["2.1.316", "1.0", "0.47.2", "10.20.30.40"] {
            #expect(VersionedExecutable.looksLikeVersion(name))
        }
        for name in ["7", "zsh", "1.", ".1", "1..2", "v2.1.0", "2.1.0-beta", "python3.12", ""] {
            #expect(!VersionedExecutable.looksLikeVersion(name))
        }
    }

    @Test func toolIsTheDirectoryAboveVersions() {
        #expect(VersionedExecutable.toolName(
            executablePath: "/Users/a/.local/share/claude/versions/2.1.316") == "claude")
        #expect(VersionedExecutable.toolName(executablePath: "/opt/claude/2.1.316") == nil)
        #expect(VersionedExecutable.toolName(executablePath: "/versions/2.1.316") == nil)
        #expect(VersionedExecutable.toolName(executablePath: "/opt/.hidden/versions/2.1") == nil)
        #expect(VersionedExecutable.toolName(executablePath: "/opt/claude/versions/latest") == nil)
    }

    @Test func aLiveVersionNamedProcessReadsAsItsTool() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-versioned-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("claude/versions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("9.8.7")
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: executable.path)
        // A platform binary copied out of /bin is killed at exec; an ad hoc
        // signature makes the copy an ordinary executable.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", executable.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)

        let pty = try PTY.spawn(executable: executable.path, arguments: [])
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }
        let deadline = SuspendingClock.now + .seconds(10)
        while SuspendingClock.now < deadline, pty.activeProcessName != "claude" {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(pty.activeProcessName == "claude")
    }
}
