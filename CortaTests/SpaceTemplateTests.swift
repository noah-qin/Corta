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

struct SpaceTemplateTests {
    @Test func aTemplateDropsIdentitiesAndResolvesRelativeDirectories() throws {
        let id = UUID()
        var claude = SpaceSessionRecord(number: 1, directory: "/work/app/web", presetName: nil)
        claude.id = id
        claude.conversation = LocalConversation(kind: .claude, id: UUID(), source: .sessionRecord)
        claude.name = "Front"
        var ssh = SpaceSessionRecord(number: 2, ssh: SSHTarget(host: "example", user: "me", port: 22))
        ssh.tmuxEstablished = true
        let member = AgentMemberRecord(role: "frontend", sessionID: id, nudgeEnabled: false)
        let template = SpaceTemplate.capture(
            name: "pair", projectPath: "/work/app", sessions: [claude, ssh],
            members: [member], layout: .panel(0))
        let data = try JSONEncoder().encode(template)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(id.uuidString))
        #expect(!text.contains("corta-"))
        #expect(!text.contains("tmux"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        let built = template.sessions(in: "/elsewhere/app")
        #expect(built[0].0.directory == "/elsewhere/app/web")
        #expect(built[0].1 == "claude")
        #expect(built[1].0.ssh?.host == "example")
        #expect(built[1].0.ssh?.identityFile == nil)
        let outside = SpaceTemplate.Session(directory: "/other", outsideProject: true, agent: "nope")
        let absolute = SpaceTemplate(name: "x", sessions: [outside], layout: nil).sessions(in: "/work/app")
        #expect(absolute[0].0.directory == "/other")
        #expect(absolute[0].1 == nil)
        let legacy = try JSONDecoder().decode(SpaceTemplate.self, from: Data(#"{"name":"old","sessions":[{}]}"#.utf8))
        #expect(legacy.sessions[0].directory == nil)
    }
}
