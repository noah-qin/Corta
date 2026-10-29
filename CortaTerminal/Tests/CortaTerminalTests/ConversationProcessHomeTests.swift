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

struct ConversationProcessHomeTests {
    private func arguments(_ environment: String) -> [UInt8] {
        [2, 0, 0, 0] + Array(("/bin/sleep\0\0sleep\0HOME=/argument-is-not-home\0" + environment).utf8)
    }

    @Test func onlyTheExactHomeEnvironmentEntryIsDecoded() {
        let bytes = arguments("SECRET=private\0NOT_HOME=/wrong\0HOME=/tmp/isolated home\0OTHER=value\0\0")
        #expect(ConversationProcess.homeDirectory(bytes: bytes)?.path == "/tmp/isolated home")
        for environment in ["OTHER=value\0\0", "HOME=relative\0\0", "HOME=\0\0",
                            "HOME=/one\0HOME=/two\0\0", "HOME=/unterminated"] {
            #expect(ConversationProcess.homeDirectory(bytes: arguments(environment)) == nil)
        }
        #expect(ConversationProcess.homeDirectory(bytes: []) == nil)
    }

    @Test func kernelHomeSelectsTheChildsSessionDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // Platform binaries hide their environment from KERN_PROCARGS2. Only
        // this disposable copy is signed; the installed executable is unchanged.
        let executable = home.appendingPathComponent("claude")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", executable.path]
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        let child = try PTY.spawn(executable: executable.path, arguments: ["10"], environment: ["HOME": home.path])
        defer { child.close() }
        let deadline = SuspendingClock.now + testTimeout(5)
        while ConversationProcess.homeDirectory(child.processIdentifier) == nil, SuspendingClock.now < deadline {
            usleep(10_000)
        }
        #expect(ConversationProcess.homeDirectory(child.processIdentifier)?.path == home.path)
        let process = try #require(ConversationProcess.read(child.processIdentifier))
        let uuid = "3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"
        let record = try JSONSerialization.data(withJSONObject: [
            "pid": process.pid, "procStart": ClaudeSessionRecord.startString(seconds: process.seconds),
            "sessionId": uuid,
        ])
        try record.write(to: sessions.appendingPathComponent(String(process.pid) + ".json"))
        #expect(child.conversationObservation?.conversation.source == .sessionRecord)
        #expect(child.conversationObservation?.conversation.id == UUID(uuidString: uuid))
    }
}
