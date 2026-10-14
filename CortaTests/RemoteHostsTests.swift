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

@testable import Corta

/// The connect dialogs' suggestions: `Host` names read from an OpenSSH
/// configuration, and the recently used hosts. Each test builds its own
/// home directory and store file under the temporary directory.
struct SSHConfigHostsTests {
    @Test("Host names are read, patterns and negations left out, comments ignored")
    func parse() {
        let parsed = SSHConfigHosts.parse(
            """
            # a comment Host not-me
            Host build-box web-1   # trailing comment
            host=lower
            Host *.internal !bastion prod-?
            Host "quoted-name"
              HostName 10.0.0.1
            Include conf.d/*
            Match host build-box exec "evil"
            """)
        #expect(parsed.hosts == ["build-box", "web-1", "lower", "quoted-name"])
        #expect(parsed.includes == ["conf.d/*"])
    }

    @Test("Include is followed, relative to ~/.ssh, bounded, and names are checked")
    func aliasesFromFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ssh-config-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        let included = ssh.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: included, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
            Host main-box
            Include conf.d/*.conf
            Include config
            Host -oProxyCommand=evil bad;name main-box
            """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host team-a team-b\n".write(
            to: included.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        // Larger than the cap: skipped whole.
        try String(repeating: "Host huge\n", count: 30_000).write(
            to: included.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)

        let aliases = SSHConfigHosts.aliases(home: home)
        // An option-shaped or punctuated name is never offered; the file
        // including itself is read once; duplicates collapse.
        #expect(aliases == ["main-box", "team-a", "team-b"])
    }

    @Test("a config that is a link, as dotfile managers make it, is followed")
    func symlinkedConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ssh-link-\(UUID().uuidString)")
        let dotfiles = home.appendingPathComponent("dotfiles")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Host linked-box\n".write(
            to: dotfiles.appendingPathComponent("ssh_config"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: ssh.appendingPathComponent("config"),
            withDestinationURL: dotfiles.appendingPathComponent("ssh_config"))
        #expect(SSHConfigHosts.aliases(home: home) == ["linked-box"])
    }

    @Test("an absent configuration is simply no aliases")
    func absent() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-no-ssh-\(UUID().uuidString)")
        #expect(SSHConfigHosts.aliases(home: home).isEmpty)
    }
}

@MainActor
struct RecentHostsStoreTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-recent-\(UUID().uuidString)")
            .appendingPathComponent("recent-hosts.json")
    }

    private func target(_ host: String, user: String = "", port: String = "") throws -> SSHTarget {
        try SSHTarget.parse(host: host, user: user, port: port).get()
    }

    @Test("newest first, no duplicates, trimmed to the limit, persisted owner-only")
    func recordAndPersist() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        for index in 0..<10 { store.record(try target("host-\(index)")) }
        store.record(try target("host-3"))
        #expect(store.targets.count == RecentHostsStore.limit)
        #expect(store.targets.first?.displayName == "host-3")
        #expect(store.targets.filter { $0.displayName == "host-3" }.count == 1)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(RecentHostsStore(fileURL: url).targets == store.targets, "read back after a relaunch")
    }

    @Test("a connection is remembered with the user, port and key it was made with")
    func recordsTheFields() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        var made = try target("box", user: "deploy", port: "2222")
        // A key that has moved since is kept: connecting says it is missing.
        made.identityFile = "/nonexistent/id_ed25519"
        store.record(made)
        #expect(RecentHostsStore(fileURL: url).targets == [made])
        // Again with another key: one entry, the newer key.
        made.identityFile = "/nonexistent/id_rsa"
        store.record(made)
        #expect(store.targets == [made])
    }

    @Test("a name no one could type is refused, from a call or from the file")
    func rejectsUnsafeNames() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        store.record(SSHTarget(host: "-oProxyCommand=evil"))
        store.record(SSHTarget(host: "box; rm -rf /"))
        store.record(SSHTarget(host: "box", user: "-oEvil"))
        store.record(SSHTarget(host: "box", identityFile: "relative/key"))
        #expect(store.targets.isEmpty)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":[],"targets":[{"host":"ok-box"},{"host":"-oEvil"},{"host":"b","port":70000}]}"#.utf8)
            .write(to: url)
        #expect(RecentHostsStore(fileURL: url).targets.map(\.displayName) == ["ok-box"])
    }

    /// An older build reads only `hosts`, and must neither find the file
    /// unreadable nor be handed `host:port` as a host name.
    @Test("the file stays readable by a build that knows only host names")
    func olderBuildsStillReadTheFile() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        store.record(SSHTarget(host: "plain", user: "deploy", identityFile: "/k"))
        store.record(SSHTarget(host: "ported", port: 2222))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect(object?["hosts"] as? [String] == ["deploy@plain"])
    }

    @Test("a version-1 file of names reads back as targets")
    func readsVersionOne() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":["ok-box","deploy@web","-oEvil","a b"]}"#.utf8).write(to: url)
        let targets = RecentHostsStore(fileURL: url).targets
        #expect(targets.map(\.displayName) == ["ok-box", "deploy@web"])
        #expect(targets.last?.user == "deploy")
    }

    @Test("remove forgets one; clear forgets all and deletes the file")
    func removeAndClear() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        store.record(try target("a-box"))
        store.record(try target("b-box"))
        store.remove(try target("a-box"))
        #expect(store.targets.map(\.displayName) == ["b-box"])
        store.clear()
        #expect(store.targets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("typing narrows the suggestions, case-insensitively")
    func filtering() {
        let names: [RemoteConnectForm.Suggestion] = [.alias("Build-Box"), .alias("web")]
        #expect(RemoteConnectForm.matching(names, "box") == [.alias("Build-Box")])
        #expect(RemoteConnectForm.matching(names, "") == names)
        let recent = RemoteConnectForm.Suggestion.recent(SSHTarget(host: "box", user: "deploy", port: 2222))
        #expect(RemoteConnectForm.matching([recent], "deploy@") == [recent], "a recent matches on its whole name")
    }
}
