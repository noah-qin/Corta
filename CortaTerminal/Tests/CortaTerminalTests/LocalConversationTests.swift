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

struct LocalConversationTests {
    private let first = "3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"
    private let second = "019eee77-052d-7530-af09-17a140e08123"

    @Test func filenamesSelectOnlyOneStandardIdentity() {
        for name in ["claude", "claude-code", "codex"] {
            let result = LocalConversation.openedFiles(processName: name, paths: ["/one/" + first + ".jsonl"])
            #expect(result?.id == UUID(uuidString: first))
            #expect(result?.command == (name == "codex" ? "codex resume " : "claude --resume ") + first)
        }
        let rollout = "/sessions/2026/10/29/rollout-2026-10-29T09-00-00-" + second + ".jsonl"
        #expect(LocalConversation.openedFiles(processName: "codex", paths: [rollout])?.id == UUID(uuidString: second))
        #expect(LocalConversation.openedFiles(processName: "claude", paths: [rollout]) == nil)
        #expect(LocalConversation.openedFiles(processName: "gemini", paths: [first + ".jsonl"]) == nil)
        #expect(LocalConversation.openedFiles(processName: "ssh", paths: [first + ".jsonl"]) == nil)
        let ambiguous = [first + ".jsonl", second + ".jsonl"]
        #expect(LocalConversation.openedFiles(processName: "claude", paths: ambiguous) == nil)
        let repeated = [first + ".jsonl", first + ".jsonl"]
        #expect(LocalConversation.openedFiles(processName: "claude", paths: repeated) != nil)
        for invalid in ["", "{" + first + "}", first + ";echo", first + " ", "task-1", first + ".jsonl.bak"] {
            #expect(LocalConversation.openedFiles(processName: "claude", paths: [invalid + ".jsonl"]) == nil)
        }
    }

    @Test func sameDirectoryProcessesKeepTheirOwnOpenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        // A copied Apple platform binary may be killed at exec. Sign only
        // this disposable copy so the fixture has an ordinary local identity.
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", executable.path]
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        // A newer, unrelated conversation is never inspected.
        try Data("private contents".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".jsonl"))
        func start(_ id: String) throws -> PTY {
            try PTYFixture.shell("exec 3>'" + directory.path + "/" + id + ".jsonl'; exec '" + executable.path + "' 30")
        }
        let one = try start(first), two = try start(second)
        defer { one.close(); two.close() }
        let deadline = SuspendingClock.now + testTimeout(5)
        while one.localConversation == nil || two.localConversation == nil, SuspendingClock.now < deadline {
            usleep(10_000)
        }
        #expect(one.localConversation?.id == UUID(uuidString: first), "kernel name: \(one.activeProcessName ?? "nil")")
        #expect(two.localConversation?.id == UUID(uuidString: second))
        #expect(one.localConversation != two.localConversation)
        one.close()
        #expect(one.localConversation == nil)
    }
}
