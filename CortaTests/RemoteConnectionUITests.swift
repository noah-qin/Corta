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

import AppKit
import CortaSFTP
import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// What the remote windows say and offer: the host a pane's ssh went to,
/// the hosts the connect dialog suggests, where a drop goes, and how a
/// failed or cancelled connection reads.
struct SSHDestinationTests {
    @Test("the destination is the first word that is not an option or its value")
    func destinationFromArgv() {
        #expect(PaneRemote.sshDestination(["box"]) == "box")
        #expect(PaneRemote.sshDestination(["-p", "2222", "deploy@box"]) == "deploy@box")
        #expect(PaneRemote.sshDestination(["-p2222", "-tt", "box", "uptime"]) == "box")
        #expect(PaneRemote.sshDestination(["-o", "ServerAliveInterval=30", "-i", "/k", "box"]) == "box")
        #expect(PaneRemote.sshDestination(["-vA", "-l", "root", "--", "box"]) == "root@box")
        #expect(PaneRemote.sshDestination(["-ldeploy", "box"]) == "deploy@box")
        #expect(PaneRemote.sshDestination(["-l", "root", "admin@box"]) == "admin@box")
        #expect(PaneRemote.sshDestination(["ssh://deploy@box:2222"]) == "deploy@box")
        #expect(PaneRemote.sshDestination(["-p", "22"]) == nil)
        #expect(PaneRemote.sshDestination([]) == nil)
    }

    @Test("the dialog offers a pane's files under the host Corta names")
    func browseHostName() {
        #expect(PaneRemote.browseHostName(state: .remote(host: "deploy@box", directory: "/srv", provenance: .osc7))
            == "deploy@box")
        #expect(PaneRemote.browseHostName(state: .connected(target: "deploy@box -p 2222", directory: nil)) != nil)
        #expect(PaneRemote.browseHostName(state: .remoteUnknown(provenance: .osc7)) == nil)
        #expect(PaneRemote.browseHostName(state: .local) == nil)
    }
}

struct GitHostTests {
    private func home(config: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("corta-git-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try config.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return home
    }

    /// `Host github.com` in `~/.ssh/config` is for git; offered as a place
    /// to log in or browse files, it only ever fails.
    @Test("git hosts are left out of the suggestions, and named as hidden")
    func gitHostsAreHidden() throws {
        let home = try home(config: """
            Host github.com
              IdentityFile ~/.ssh/id_ed25519
            Host gh-work
              HostName ssh.github.com
            Host forge
              User git
            Host staging prod
              User deploy
            Match host *.internal
              User git
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let found = SSHConfigHosts.suggestions(home: home)
        #expect(found.hosts == ["staging", "prod"])
        #expect(found.hiddenGitHosts == ["github.com", "gh-work", "forge"])
        // Everything is still an alias; only the dialog leaves them out.
        #expect(SSHConfigHosts.aliases(home: home).count == 5)
    }

    @Test("a git host is the service or one of its subdomains, with or without a user")
    func isGitHost() {
        #expect(SSHConfigHosts.isGitHost("github.com"))
        #expect(SSHConfigHosts.isGitHost("git@GitHub.com"))
        #expect(SSHConfigHosts.isGitHost("altssh.gitlab.com"))
        #expect(!SSHConfigHosts.isGitHost("notgithub.com"))
        #expect(!SSHConfigHosts.isGitHost("47.94.76.159"))
    }
}

@MainActor
struct RecentHostTimeTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-recent-\(UUID().uuidString)")
            .appendingPathComponent("recent-hosts.json")
    }

    @Test("when a host was last used is kept, read back, and forgotten with it")
    func lastUsedPersists() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        let box = try SSHTarget.parse(host: "box", user: "deploy", port: "").get()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(box, at: when)
        #expect(RecentHostsStore(fileURL: url).lastUsed(box) == when)
        store.remove(box)
        #expect(RecentHostsStore(fileURL: url).lastUsed(box) == nil)
    }

    /// An older build's file has no times; it still reads, and its hosts
    /// simply have none.
    @Test("a file without times reads back")
    func olderFileReads() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":["deploy@box"],"targets":[{"host":"box","user":"deploy"}]}"#.utf8)
            .write(to: url)
        let store = RecentHostsStore(fileURL: url)
        let box = try #require(store.targets.first)
        #expect(box.displayName == "deploy@box")
        #expect(store.lastUsed(box) == nil)
    }

    @Test("a recent's detail says what was set and when, leaving out what was not")
    func recentDetail() throws {
        let plain = try SSHTarget.parse(host: "box", user: "", port: "").get()
        #expect(RemoteConnectSuggestionList.recentDetail(plain, lastUsed: nil, now: Date())
            == [L10n.text("ui.connect.userFromConfig"), L10n.text("ui.connect.identityDefault")]
                .joined(separator: " · "))
        let full = try SSHTarget.parse(host: "box", user: "deploy", port: "2222").get()
        let detail = RemoteConnectSuggestionList.recentDetail(
            full, lastUsed: Date(timeIntervalSinceNow: -7200), now: Date())
        #expect(detail.hasPrefix(L10n.format("ui.connect.portValue", "2222")))
        #expect(detail.split(separator: "·").count == 3)
    }
}

@MainActor
struct SFTPDropDestinationTests {
    private let entries = [
        SFTPBrowserModel.Entry(name: "releases", kind: .directory, size: nil, modified: nil, permissions: nil),
        SFTPBrowserModel.Entry(name: "notes.txt", kind: .file, size: 1, modified: nil, permissions: nil),
    ]

    @Test("a drop on a folder row goes into that folder; anywhere else, the folder shown")
    func destination() {
        #expect(SFTPDropDestination.resolve(row: 0, entries: entries, currentPath: "/srv")
            == .folder(path: "/srv/releases", name: "releases"))
        #expect(SFTPDropDestination.resolve(row: 1, entries: entries, currentPath: "/srv")
            == .current(path: "/srv"))
        #expect(SFTPDropDestination.resolve(row: nil, entries: entries, currentPath: "/srv")
            == .current(path: "/srv"))
        #expect(SFTPDropDestination.resolve(row: 9, entries: entries, currentPath: "/")
            == .current(path: "/"))
    }

    @Test("the listing says where the files will go")
    func prompt() {
        #expect(SFTPDropDestination.current(path: "/srv").prompt(count: 2)
            == L10n.format("sftp.drop.current", 2, "srv"))
        #expect(SFTPDropDestination.current(path: "/").prompt(count: 1)
            == L10n.format("sftp.drop.current", 1, "/"))
        #expect(SFTPDropDestination.folder(path: "/srv/releases", name: "releases").prompt(count: 2)
            == L10n.format("sftp.drop.folder", "releases"))
    }
}

@MainActor
struct SFTPConnectFailureTests {
    @Test("each kind of failure has its own sentence, and ssh's words go to Details")
    func classified() {
        let auth = SFTPBrowserModel.connectFailure(
            .transport(.authenticationFailed(diagnostics: "Permission denied (publickey,password).")),
            host: "deploy@box")
        #expect(auth.title == L10n.format("sftp.failure.auth.title", "deploy@box"))
        #expect(auth.body == L10n.text("sftp.failure.auth.body"))
        #expect(auth.details.contains("Permission denied (publickey,password)."))

        let kinds: [SFTPError] = [
            .transport(.authenticationFailed(diagnostics: "")),
            .transport(.hostUnreachable(diagnostics: "")),
            .transport(.hostKeyUnverified(diagnostics: "")),
            .transport(.subprocessFailed(exitCode: 1, diagnostics: "")),
            .transport(.connectionLost),
            .transport(.spawnFailed(code: 2)),
        ]
        let titles = Set(kinds.map { SFTPBrowserModel.connectFailure($0, host: "box").title })
        #expect(titles.count == kinds.count)
    }

    @Test("a failed connection is shown as a failure; a typo in the fields is not")
    func failureIsKept() async {
        let fake = FakeSFTPClient()
        fake.connectError = .transport(.hostUnreachable(diagnostics: "no route"))
        let model = SFTPBrowserModel(host: "far-box", startDirectory: nil) { _ in fake }
        model.connect()
        await waitUntil("failed") { model.isFailed }
        #expect(model.connectFailure?.title == L10n.format("sftp.failure.unreachable.title", "far-box"))
        // Edit Connection: back to the fields, the failure gone.
        model.cancelConnect()
        #expect(model.connectionState == .needsHost)
        #expect(model.connectFailure == nil)
    }

    /// The password dialog's Cancel ends the connection's ssh; the window
    /// goes back to its host field rather than reporting a failure.
    @Test("a refused password returns to the host field, for that host only")
    func refusedPassword() {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: "slow-box", startDirectory: nil) { _ in fake }
        model.connect()
        #expect(model.connectionState == .connecting)
        model.passwordRefused(host: "other-box")
        #expect(model.connectionState == .connecting)
        model.passwordRefused(host: "slow-box")
        #expect(model.connectionState == .needsHost)
        #expect(model.hostField == "slow-box")
        #expect(model.connectFailure == nil)
    }
}

@MainActor
struct AskpassWordingTests {
    @Test("the field names what ssh asked for")
    func placeholder() {
        #expect(SSHAskpassPrompter.placeholder(for: "deploy@box's password: ")
            == L10n.text("askpass.placeholder.password"))
        #expect(SSHAskpassPrompter.placeholder(for: "Enter passphrase for key '/k': ")
            == L10n.text("askpass.placeholder.passphrase"))
        #expect(SSHAskpassPrompter.placeholder(for: "Verification code: ")
            == L10n.text("askpass.placeholder.answer"))
    }

    /// The prompt names the host already; the dialog says it once more in
    /// its title, not twice more.
    @Test("a password dialog says Cancel ends the connection")
    func cancelSaysWhatItDoes() {
        let alert = SSHAskpassPrompter.makeAlert(.secret, host: "deploy@box", prompt: "deploy@box's password:")
        #expect(alert.buttons.map(\.title) == [
            L10n.text("askpass.continue"), L10n.text("askpass.cancelConnection"),
        ])
        #expect(alert.informativeText.contains(L10n.text("askpass.source.short")))
        #expect(!alert.informativeText.contains(L10n.text("askpass.source")))
        #expect((alert.accessoryView as? NSSecureTextField)?.placeholderString
            == L10n.text("askpass.placeholder.password"))
        // A passphrase's Cancel skips the key; it says only Cancel.
        let passphrase = SSHAskpassPrompter.makeAlert(
            .secret, host: "box", prompt: "Enter passphrase for key '/k':")
        #expect(passphrase.buttons.last?.title == L10n.text("common.cancel"))
        #expect(!SSHAskpass.refusalEndsConnection(kind: .secret, prompt: "Enter passphrase for key '/k':"))
        #expect(SSHAskpass.refusalEndsConnection(kind: .secret, prompt: "Verification code:"))
        #expect(!SSHAskpass.refusalEndsConnection(kind: .confirm, prompt: "Allow use of key?"))
    }
}
