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

/// A project's layout, without identities, commands or credentials.
nonisolated struct SpaceTemplate: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        var presetName: String?
        var sshHost: String?
        var sshUser: String?
        var sshPort: Int?
        /// Relative to the project, or absolute when `outsideProject` is set.
        var directory: String?
        var outsideProject: Bool?
        var name: String?
        var agent: String?
        var memberRole: String?
        var nudgeEnabled: Bool?
    }

    var name: String
    var sessions: [Session]
    var layout: SpaceLayoutRecord?

    static func capture(name: String, projectPath: String, sessions: [SpaceSessionRecord],
                        members: [AgentMemberRecord], layout: SpaceLayoutRecord?) -> SpaceTemplate {
        let captured = sessions.map { record in
            let member = members.first { $0.sessionID == record.id }
            let directory = relative(record.directory, to: projectPath)
            return Session(
                presetName: record.presetName,
                sshHost: record.ssh?.host,
                sshUser: record.ssh?.user,
                sshPort: record.ssh?.port,
                directory: directory.path,
                outsideProject: directory.outside ? true : nil,
                name: record.name,
                agent: record.conversation?.kind.rawValue,
                memberRole: member?.role,
                nudgeEnabled: member == nil ? nil : member?.nudgeEnabled)
        }
        return SpaceTemplate(name: name, sessions: captured, layout: layout)
    }

    /// Records to start in `projectPath`. Agent kinds are returned beside them for the prompt fill.
    func sessions(in projectPath: String) -> [(SpaceSessionRecord, String?)] {
        sessions.map { session in
            var directory = session.directory
            if session.outsideProject != true, let relative = directory {
                directory = relative.isEmpty ? projectPath : (projectPath as NSString).appendingPathComponent(relative)
            }
            let ssh = session.sshHost.flatMap { host in
                SSHTarget(host: host, user: session.sshUser, port: session.sshPort, identityFile: nil)
            }
            var record = SpaceSessionRecord(
                number: 1, directory: ssh == nil ? directory : nil, presetName: session.presetName, ssh: ssh)
            record.name = session.name
            let agent = session.agent == "claude" || session.agent == "codex" ? session.agent : nil
            return (record, agent)
        }
    }

    private static func relative(_ directory: String?, to project: String) -> (path: String?, outside: Bool) {
        guard let directory else { return (nil, false) }
        if directory == project { return ("", false) }
        let prefix = project.hasSuffix("/") ? project : project + "/"
        if directory.hasPrefix(prefix) { return (String(directory.dropFirst(prefix.count)), false) }
        return (directory, true)
    }
}

nonisolated struct SpaceTemplateFile: Codable, Equatable, Sendable {
    var templates: [SpaceTemplate] = []

    static func load(from url: URL) -> SpaceTemplateFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SpaceTemplateFile.self, from: data) else { return SpaceTemplateFile() }
        return file
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    static var url: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("space-templates.json")
    }
}
