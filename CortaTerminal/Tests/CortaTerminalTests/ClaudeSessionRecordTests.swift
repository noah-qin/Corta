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

struct ClaudeSessionRecordTests {
    private let uuid = "3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"
    private let process = ConversationProcess(pid: 123, seconds: 1_793_294_822, microseconds: 12, name: "claude")

    private func withRecord(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, directory.appendingPathComponent("123.json"))
    }

    private func record(pid: Int32 = 123, start: String? = nil, id: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "pid": pid, "procStart": start ?? ClaudeSessionRecord.startString(seconds: process.seconds),
            "sessionId": id ?? uuid, "unrelated": "never persisted",
        ])
    }

    @Test func verifiedRecordAndCacheUsePIDAndKernelStartTime() throws {
        try withRecord { directory, file in
            try record().write(to: file)
            var cache = ClaudeConversationCache()
            let first = cache.read(process: process, directory: directory, verify: { true })
            #expect(first.conversation.source == .sessionRecord)
            #expect(first.conversation.id == UUID(uuidString: uuid))
            #expect(first.reason == nil)
            try Data("not json".utf8).write(to: file)
            #expect(cache.read(process: process, directory: directory, verify: { true }) == first,
                    "the same PID and subsecond kernel start are read only once")
            let reused = ConversationProcess(pid: 123, seconds: process.seconds,
                                             microseconds: 13, name: "claude")
            #expect(cache.read(process: reused, directory: directory, verify: { true }).reason == .recordUnreadable)
        }
    }

    @Test func aLateCreatedRecordIsReadOnceAfterTheProcessAppears() throws {
        try withRecord { directory, file in
            var cache = ClaudeConversationCache()
            let missing = cache.read(process: process, directory: directory, verify: { true })
            #expect(missing.conversation.source == .picker)
            #expect(missing.reason == .recordMissing)
            try record().write(to: file)
            let created = cache.read(process: process, directory: directory, verify: { true })
            #expect(created.conversation.source == .sessionRecord)
            #expect(created.reason == nil)
            try FileManager.default.removeItem(at: file)
            #expect(cache.read(process: process, directory: directory, verify: { true }) == created)
        }
    }

    @Test func everyRecordFailureReportsPickerAndItsReason() throws {
        try withRecord { directory, file in
            func expect(_ reason: ConversationObservation.Reason, verify: () -> Bool = { true }) {
                let result = ClaudeSessionRecord.read(process: process, directory: directory, verify: verify)
                #expect(result.conversation.source == .picker)
                #expect(result.conversation.id == nil)
                #expect(result.conversation.command == "claude --resume")
                #expect(result.reason == reason)
            }
            expect(.recordMissing)
            try Data(repeating: 32, count: ClaudeSessionRecord.maximumBytes + 1).write(to: file)
            expect(.recordTooLarge)
            try Data("not JSON".utf8).write(to: file)
            expect(.recordUnreadable)
            try Data("{}".utf8).write(to: file)
            expect(.fieldMissing)
            for invalid in [uuid + ";echo", uuid + " ", "{" + uuid + "}"] {
                try record(id: invalid).write(to: file)
                expect(.notStandardUUID)
            }
            try record(pid: 124).write(to: file)
            expect(.processMismatch)
            try record(start: "Thu Oct 29 00:00:00 2026").write(to: file)
            expect(.processMismatch)
            try record().write(to: file)
            expect(.processMismatch, verify: { false })
            var checks = 0
            expect(.processMismatch, verify: { checks += 1; return checks == 1 })
            try FileManager.default.removeItem(at: file)
            let target = directory.appendingPathComponent("target")
            try record().write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            expect(.recordUnreadable)
        }
    }

    @Test func nativeVersionNamedExecutableUsesOnlyTheInvocationName() {
        let prefix: [UInt8] = [3, 0, 0, 0]
        let args = "/home/example/.local/share/claude/versions/2.1.312\0\0/home/example/.local/bin/claude\0"
            + "secret argument\0SECRET=private\0"
        #expect(ConversationProcess.invocationName(bytes: prefix + Array(args.utf8)) == "claude")
        #expect(ConversationProcess.invocationName(bytes: []) == nil)
        #expect(ConversationProcess.invocationName(bytes: prefix + Array("unterminated".utf8)) == nil)
        let other = prefix + Array("/bin/node\0\0node\0claude\0".utf8)
        #expect(ConversationProcess.invocationName(bytes: other) == "node", "later arguments are never names")
    }

    @Test func wholeGroupRecognizesNodeWrappedCodexAndRejectsMixedAgents() {
        let node = ConversationProcess(pid: 100, seconds: 1, microseconds: 0, name: "node")
        let codex = ConversationProcess(pid: 101, seconds: 1, microseconds: 0, name: "codex")
        let result = ConversationObservation.recognized([node, codex])
        #expect(result?.0 == .codex)
        #expect(result?.1 == [codex])
        #expect(ConversationObservation.recognized([node]) == nil)
        #expect(ConversationObservation.recognized([node, codex, process]) == nil)
        #expect(ConversationSample.isMixed([node, codex, process]))
        #expect(!ConversationSample.isMixed([node, codex]))
    }

    @Test func codexFallbacksExposeReasonsAndNeverGuessANonRolloutFile() {
        for (files, reason) in [
            ([], ConversationObservation.Reason.noOpenFile),
            ([LocalConversation.OpenedFile(path: uuid + ".jsonl")], .noOpenFile),
            ([LocalConversation.OpenedFile(path: "rollout-date-" + uuid + ".jsonl"),
              LocalConversation.OpenedFile(path: "rollout-date-019eee77-052d-7530-af09-17a140e08123.jsonl")],
             .ambiguousOpenFiles),
        ] {
            let result = ConversationObservation.codex(processes: [], files: files)
            #expect(result.conversation.source == .picker)
            #expect(result.conversation.command == "codex resume")
            #expect(result.reason == reason)
        }
        #expect(ConversationObservation.codex(processes: [], files: nil).reason == .openFilesUnreadable)
    }

    @Test func failedProbeRetainsVerifiedUUIDOnlyForSameAgentProcess() {
        let previous = LocalConversation(kind: .claude, id: UUID(uuidString: uuid), source: .sessionRecord)
        let fallback = ConversationObservation(kind: .claude, processes: [process], reason: .recordMissing)
        let retained = fallback.retainingIdentity(previous, previousProcesses: [process])
        #expect(retained.id == previous.id)
        #expect(retained.source == .sessionRecord)
        #expect(fallback.reason == .recordMissing)
        #expect(fallback.retainingIdentity(previous, previousProcesses: []).id == nil)
        #expect(fallback.retainingIdentity(previous, previousProcesses: nil).command == "claude --resume")
    }
    @Test func failuresRetryWithinAFiniteBudgetAndOnlySuccessIsCached() throws {
        for invalid in [Data("partial JSON".utf8), try record(pid: 124)] {
            try withRecord { directory, file in
                var cache = ClaudeConversationCache()
                try invalid.write(to: file)
                #expect(cache.read(process: process, directory: directory, verify: { true }).reason != nil)
                try record().write(to: file)
                #expect(cache.read(process: process, directory: directory, verify: { true }).conversation.source
                        == .sessionRecord)
            }
        }
        try withRecord { directory, file in
            var cache = ClaudeConversationCache()
            try Data("partial JSON".utf8).write(to: file)
            var checks = 0
            for _ in 0..<10 {
                #expect(cache.read(process: process, directory: directory, verify: {
                    checks += 1
                    return true
                }).reason == .recordUnreadable)
            }
            #expect(checks == ClaudeConversationCache.maximumAttempts)
            try record().write(to: file)
            #expect(cache.read(process: process, directory: directory, verify: { true }).conversation.id == nil)
            let replacement = ConversationProcess(pid: 123, seconds: process.seconds,
                                                  microseconds: 13, name: "claude")
            #expect(cache.read(process: replacement, directory: directory, verify: { true }).conversation.source
                    == .sessionRecord)
        }
    }

    @Test func realClaude21312ProcStartLiteralMatchesKernelEpoch() throws {
        // Copied verbatim from the 2.1.312 process record during the #436
        // acceptance run, 2026-10-30 local time. No conversation content.
        try withRecord { directory, file in
            try record(start: "Thu Oct 29 17:27:02 2026").write(to: file)
            let result = ClaudeSessionRecord.read(process: process, directory: directory, verify: { true })
            #expect(result.conversation.source == .sessionRecord)
            #expect(result.reason == nil)
        }
    }

    @Test func codexClosedRolloutRetainsItsOriginalSource() {
        let agent = ConversationProcess(pid: 456, seconds: 1, microseconds: 2, name: "codex")
        let success = ConversationObservation.codex(processes: [agent], files: [
            LocalConversation.OpenedFile(path: "rollout-date-" + uuid + ".jsonl"),
        ])
        for files: [LocalConversation.OpenedFile]? in [[], nil] {
            let failure = ConversationObservation.codex(processes: [agent], files: files)
            let retained = failure.retainingIdentity(success.conversation, previousProcesses: [agent])
            #expect(retained == success.conversation)
            #expect(retained.source == .openFile)
            #expect(retained.command.contains(uuid))
            #expect(failure.reason != nil)
        }
    }

}
