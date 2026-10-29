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

import CortaTerminal
import Foundation
import Testing
@testable import Corta

struct SpaceConversationTests {
    private let uuid = "3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"

    @Test func legacyMalformedAndRemoteRecordsLeaveOrdinaryShells() throws {
        func decode(_ fields: String) throws -> SpaceSessionRecord {
            try JSONDecoder().decode(SpaceSessionRecord.self, from: Data(("{\"number\":1" + fields + "}").utf8))
        }
        #expect(try decode("").conversation == nil)
        for invalid in ["", uuid + ";echo", uuid + " ", "{" + uuid + "}", "task-123"] {
            let metadata = #", "conversation":{"kind":"claude","id":"\#(invalid)"}"#
            #expect(try decode(metadata).conversation == nil)
        }
        for fields in [#", "conversation":{"kind":"gemini","id":"\#(uuid)"}"#,
                       #", "conversation":{"id":"\#(uuid)"}"#,
                       #", "conversation":{"kind":"claude"}"#,
                       #", "conversation":42"#] {
            #expect(try decode(fields).conversation == nil)
        }
        let valid = #", "conversation":{"kind":"claude","id":"\#(uuid)"}"#
        #expect(try decode(valid).conversation?.command == "claude --resume " + uuid)
        #expect(try decode(valid + #", "ssh":{"host":"fixture"}"#).conversation == nil)
    }

    @Test func aCursorAtHomeWithTypedTextIsNotAnEmptyPrompt() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("$ ".utf8))
        #expect(CortaSpaceController.isEmptyConversationPrompt(in: terminal.grid, row: 0, column: 2))
        terminal.feed(Array("do not overwrite\u{1b}[3G".utf8))
        #expect(!CortaSpaceController.isEmptyConversationPrompt(in: terminal.grid, row: 0, column: 2))
        terminal.feed(Array("\u{1b}[K".utf8))
        #expect(CortaSpaceController.isEmptyConversationPrompt(in: terminal.grid, row: 0, column: 2))
        terminal.feed(Array("\u{1b}[?1049h".utf8))
        #expect(!CortaSpaceController.isEmptyConversationPrompt(in: terminal.grid, row: 0, column: 2))
    }

    @Test @MainActor func persistenceContainsOnlyKindAndUUIDAndRejectsDuplicateKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpaceStore(directory: directory)
        var record = SpaceSessionRecord(number: 1)
        record.conversation = LocalConversation(kind: .codex, id: try #require(UUID(uuidString: uuid)))
        let state = SpaceState(projects: [SpaceProjectRecord(path: "/fixture", sessions: [record])])
        store.save(state)
        #expect(store.load(isDirectory: { _ in true }).projects[0].sessions[0].conversation == record.conversation)
        let data = try Data(contentsOf: store.fileURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try #require(object["projects"] as? [[String: Any]])
        let sessions = try #require(projects[0]["sessions"] as? [[String: Any]])
        let conversation = try #require(sessions[0]["conversation"] as? [String: Any])
        #expect(Set(conversation.keys) == ["kind", "id"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("resume"))
        #expect(!text.contains("jsonl"))
        for duplicate in [#""id":"\#(uuid)","id":"\#(uuid)""#,
                          #""id":"\#(uuid)","i\u0064":"\#(uuid)""#] {
            let json = #"{"version":1,"projects":[{"path":"/fixture","sessions":["#
                + #"{"number":1,"conversation":{"kind":"claude","#
                + duplicate + #"}}],"nextNumber":2}]}"#
            try Data(json.utf8).write(to: store.fileURL)
            #expect(store.load(isDirectory: { _ in true }).projects[0].sessions[0].conversation == nil)
        }
    }
}
