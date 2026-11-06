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
    @Test("a deadline cancelled as its last tick finishes cannot fail the connection")
    func aCancelledFinalTickCannotFailTheConnection() async {
        let fake = FakeSFTPClient()
        fake.connectHangs = true
        let model = SFTPBrowserModel(host: "slow-box", startDirectory: nil) { _ in fake }
        defer { model.disconnect() }
        model.connectTimeout = .milliseconds(20)
        var cancelledAtTheDeadline = false
        model.isAskingHost = { [weak model] _ in
            // The last tick's clock has elapsed, but wait has not returned
            // yet. Completion/re-arming can cancel the task at this boundary.
            cancelledAtTheDeadline = true
            model?.connectDeadline?.cancel()
            return false
        }
        model.connect()
        await waitUntil("the last deadline tick") { cancelledAtTheDeadline }
        await model.connectDeadline?.value
        #expect(model.connectionState == .connecting)
        #expect(model.connectFailure == nil)
        #expect(!fake.closed)
    }

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
    /// No answer from a host that swallows packets: ssh would wait out the
    /// kernel's own timeout with the window saying Connecting.
    @Test("a connection that does not answer fails in time, and can be retried")
    func connectingHasADeadline() async {
        let first = FakeSFTPClient()
        first.connectHangs = true
        let second = FakeSFTPClient()
        second.listings["/home/tester"] = []
        let clients = Guarded(wrappedValue: [first, second])
        let model = SFTPBrowserModel(host: "slow-box", startDirectory: nil) { _ in
            clients.mutate { $0.removeFirst() }
        }
        model.connectTimeout = .milliseconds(50)
        model.connect()
        await waitUntil("failed") { model.isFailed }
        #expect(first.closed)
        #expect(model.client == nil)
        #expect(model.connectFailure?.title == L10n.format("sftp.failure.unreachable.title", "slow-box"))
        // The retry is not what is under test: it gets the time a real one does.
        model.connectTimeout = .seconds(30)
        model.retry()
        await waitUntil("reconnected") { model.connectionState == .connected }
        model.disconnect()
    }

    /// Typing a password must not be what disconnects the user: the time a
    /// question is on screen is not the server's to answer for.
    @Test("a question on screen stops the connection's clock")
    func theDeadlineWaitsForAnAnswer() async throws {
        let fake = FakeSFTPClient()
        fake.connectHangs = true
        let model = SFTPBrowserModel(host: "deploy@slow-box:2222", startDirectory: nil) { _ in fake }
        model.connectTimeout = .milliseconds(100)
        let asking = Guarded(wrappedValue: true)
        let asked = Guarded(wrappedValue: [String]())
        model.isAskingHost = { host in
            asked.mutate { $0.append(host) }
            return asking.wrappedValue
        }
        model.connect()
        await waitUntil("the clock running") { !asked.wrappedValue.isEmpty }
        #expect(asked.wrappedValue.first == "deploy@slow-box:2222", "by the name the dialog carries")
        // Many times the deadline, with the question up.
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.connectionState == .connecting)
        asking.wrappedValue = false
        await waitUntil("failed once answered") { model.isFailed }
        model.disconnect()
    }

    @Test("a late answer from a connection given up on changes nothing")
    func aLateConnectIsIgnored() async {
        let fake = FakeSFTPClient()
        fake.connectHangs = true
        let model = SFTPBrowserModel(host: "slow-box", startDirectory: nil) { _ in fake }
        model.connectTimeout = .milliseconds(30)
        model.connect()
        await waitUntil("failed") { model.isFailed }
        let failure = model.connectFailure
        // `close` lets the hung connect end, with an error of its own.
        fake.closed = true
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.connectFailure == failure)
    }

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

    /// A password prompt is usually the local ssh's and a keyboard-interactive
    /// one the server's, and the app cannot tell which it holds: the line under
    /// it says either may have written it.
    @Test("a password dialog says who may have asked, and Cancel ends the connection")
    func cancelSaysWhatItDoes() {
        let alert = SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(
            question: .secret, host: "deploy@box", prompt: "deploy@box's password:",
            refusalEndsConnection: true))
        #expect(alert.buttons.map(\.title) == [
            L10n.text("askpass.continue"), L10n.text("askpass.cancelConnection"),
        ])
        #expect(alert.informativeText.contains(L10n.text("askpass.source")))
        #expect((alert.accessoryView as? NSSecureTextField)?.placeholderString
            == L10n.text("askpass.placeholder.password"))
        // A passphrase's Cancel skips the key; it says only Cancel.
        let passphrase = SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(
            question: .secret, host: "box", prompt: "Enter passphrase for key '/k':"))
        #expect(passphrase.buttons.last?.title == L10n.text("common.cancel"))
        #expect(!SSHAskpass.refusalEndsConnection(kind: .secret, prompt: "Enter passphrase for key '/k':"))
        #expect(SSHAskpass.refusalEndsConnection(kind: .secret, prompt: "Verification code:"))
        #expect(!SSHAskpass.refusalEndsConnection(kind: .confirm, prompt: "Allow use of key?"))
    }

    /// What the dialog does is what the broker decided, never read back out
    /// of the text it shows.
    @Test("Cancel's wording follows the broker's decision, not the prompt")
    func cancelFollowsTheBroker() {
        let ends = SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(
            question: .secret, host: "box", prompt: "Enter passphrase", refusalEndsConnection: true))
        #expect(ends.buttons.last?.title == L10n.text("askpass.cancelConnection"))
        let skips = SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(
            question: .secret, host: "box", prompt: "Password:", refusalEndsConnection: false))
        #expect(skips.buttons.last?.title == L10n.text("common.cancel"))
    }

    /// `ProxyJump bastion`: bastion's inner ssh asks, and the connection's
    /// destination is prod. Nothing Corta writes may call that prod's question.
    @Test("a question from below the connection's ssh does not name the destination as asking")
    func anIntermediateStepIsSaidToBeOne() {
        let asking = { (question: SSHAskpass.Question, prompt: String) in
            SSHAskpass.Asking(
                question: question, host: "deploy@prod", prompt: prompt, isIntermediateStep: true,
                refusalEndsConnection: question == .secret)
        }
        let secret = SSHAskpassPrompter.makeAlert(asking(.secret, "bastion's password:"))
        #expect(secret.messageText == L10n.format("askpass.secret.title.intermediate", "deploy@prod"))
        #expect(secret.messageText != L10n.format("askpass.secret.title", "deploy@prod"))
        #expect(secret.informativeText.contains("bastion's password:"))
        #expect(secret.informativeText.contains(L10n.format("askpass.source.intermediate", "deploy@prod")))
        #expect((secret.accessoryView as? NSSecureTextField)?.accessibilityLabel() == secret.messageText)

        let hostKey = SSHAskpassPrompter.makeAlert(asking(.hostKey, "bastion's fingerprint (yes/no)?"))
        #expect(hostKey.messageText == L10n.format("askpass.hostKey.title.intermediate", "deploy@prod"))
        #expect(hostKey.informativeText.contains(L10n.format("askpass.hostKey.advice.intermediate", "deploy@prod")))
        #expect(!hostKey.informativeText.contains(L10n.text("askpass.hostKey.advice")))
        // Return must not trust a key unread, here above all.
        #expect(hostKey.buttons.map(\.title) == [L10n.text("common.cancel"), L10n.text("askpass.hostKey.trust")])
        #expect(SSHAskpassPrompter.acceptResponse(.hostKey) == .alertSecondButtonReturn)

        #expect(SSHAskpassPrompter.makeAlert(asking(.confirm, "Allow?")).messageText
            == L10n.format("askpass.confirm.title.intermediate", "deploy@prod"))
        #expect(SSHAskpassPrompter.makeAlert(asking(.notify, "Touch")).messageText
            == L10n.format("askpass.notify.title.intermediate", "deploy@prod"))
    }

    @Test("the connection's own ssh asks in the destination's name")
    func aDirectQuestionNamesTheDestination() {
        let direct = { (question: SSHAskpass.Question) in
            SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(question: question, host: "prod", prompt: "?"))
        }
        #expect(direct(.secret).messageText == L10n.format("askpass.secret.title", "prod"))
        #expect(direct(.hostKey).messageText == L10n.format("askpass.hostKey.title", "prod"))
        #expect(direct(.hostKey).informativeText.contains(L10n.text("askpass.hostKey.advice")))
        #expect(direct(.hostKey).buttons.first?.title == L10n.text("common.cancel"))
    }

    /// Whether AppKit ends a sheet when its parent is closed from under it is
    /// not something it promises, and ssh would wait on that sheet for ever.
    @Test("a question ends when the window it hangs on is closed")
    func theSheetFollowsItsWindow() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let alert = SSHAskpassPrompter.makeAlert(SSHAskpass.Asking(question: .hostKey, host: "box", prompt: "?"))
        let answered = Guarded(wrappedValue: false)
        let answer = Task { @MainActor in
            let result = await SSHAskpassPrompter.answer(alert, field: nil, question: .hostKey, on: window)
            answered.wrappedValue = true
            return result
        }
        await waitUntil("sheet up") { window.attachedSheet != nil }
        window.close()
        await waitUntil("answered") { answered.wrappedValue }
        // Awaited only once answered: unanswered, this would hang the suite.
        if answered.wrappedValue { #expect(await answer.value == nil) }
    }
}
