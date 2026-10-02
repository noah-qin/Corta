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

    @Test("newest first, no duplicates, trimmed to the limit, persisted owner-only")
    func recordAndPersist() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        for index in 0..<10 { store.record("host-\(index)") }
        store.record("host-3")
        #expect(store.hosts.count == RecentHostsStore.limit)
        #expect(store.hosts.first == "host-3")
        #expect(store.hosts.filter { $0 == "host-3" }.count == 1)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(RecentHostsStore(fileURL: url).hosts == store.hosts, "read back after a relaunch")
    }

    @Test("a name no one could type is refused, from a call or from the file")
    func rejectsUnsafeNames() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        store.record("-oProxyCommand=evil")
        store.record("box; rm -rf /")
        #expect(store.hosts.isEmpty)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":["ok-box","-oEvil","a b"]}"#.utf8).write(to: url)
        #expect(RecentHostsStore(fileURL: url).hosts == ["ok-box"])
    }

    @Test("remove forgets one; clear forgets all and deletes the file")
    func removeAndClear() {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        store.record("a-box")
        store.record("b-box")
        store.remove("a-box")
        #expect(store.hosts == ["b-box"])
        store.clear()
        #expect(store.hosts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("typing narrows the suggestions, case-insensitively")
    func filtering() {
        #expect(RemoteConnectForm.matching(["Build-Box", "web"], "box") == ["Build-Box"])
        #expect(RemoteConnectForm.matching(["a", "b"], "") == ["a", "b"])
    }
}
