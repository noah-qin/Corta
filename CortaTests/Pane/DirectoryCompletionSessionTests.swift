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
import CortaTerminal
@testable import Corta

@MainActor
struct DirectoryCompletionSessionTests {
    @Test("startup folders a crashed run left are removed once a day old, and nothing else")
    func staleStartupFoldersAreRemoved() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("corta-stale-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let old = root.appendingPathComponent(ZshBootstrap.folderPrefix + "old")
        let fresh = root.appendingPathComponent(ZshBootstrap.folderPrefix + "fresh")
        let other = root.appendingPathComponent("someone-else")
        for url in [old, fresh, other] { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        let now = Date()
        let dayAgo = now.addingTimeInterval(-ZshBootstrap.staleAge - 60)
        try fileManager.setAttributes([.modificationDate: dayAgo], ofItemAtPath: old.path)
        try fileManager.setAttributes([.modificationDate: dayAgo], ofItemAtPath: other.path)
        ZshBootstrap.removeStaleFolders(in: root, now: now)
        #expect(!fileManager.fileExists(atPath: old.path))
        #expect(fileManager.fileExists(atPath: fresh.path), "the other build may be starting a shell from it")
        #expect(fileManager.fileExists(atPath: other.path))
    }

    /// A home of folders to complete — plain, nested, linked, with spaces,
    /// a quote and a leading dash — a file, and a `.zshrc` that must not
    /// change.
    private static func makeCompletionHome() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("corta-cd-session-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        for name in ["Alpha", "Another", "空格 中文", "quote'name", ".hidden", "-dash"] {
            try fileManager.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(
            at: home.appendingPathComponent("Another/Child/Grandchild"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("Linked"), withDestinationURL: home.appendingPathComponent("Alpha"))
        try "not a directory".write(to: home.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try "PS1='READY> '\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return home
    }

    /// Polls `predicate` for up to five seconds; a timeout fails with the
    /// screen.
    private static func wait(for session: TerminalSession, until predicate: () -> Bool) throws {
        let end = SuspendingClock.now + .seconds(5 * Double(testTimeoutScale))
        while SuspendingClock.now < end {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(Bool(false), "\(session.snapshot().dump())")
    }

    @Test func shellOwnsFilteringAndAcceptance() throws {
        let home = try Self.makeCompletionHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8", "TERM_PROGRAM": "Corta",
        ]
        let prepared = ZshBootstrap.prepare(environment, executable: "/bin/zsh", arguments: ["-l"])
        let env = prepared.environment, made = prepared.folder, token = prepared.token
        let folder = try #require(made)
        defer { ZshBootstrap.remove(folder) }
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 40, columns: 120), workingDirectory: home.path,
            directoryCompletionToken: token)
        defer { session.stop() }
        session.start()
        func wait(_ predicate: () -> Bool) throws { try Self.wait(for: session, until: predicate) }
        func write(_ value: String) { session.write(Array(value.utf8)) }
        try wait { session.promptEndPosition != nil }
        write("cd ")
        try wait { session.directoryCompletion?.candidates.contains("Alpha/") == true }
        #expect(session.directoryCompletion?.candidates.contains("file/") == false)
        #expect(session.directoryCompletion?.candidates.contains("Linked/") == true)
        #expect(session.directoryCompletion?.candidates.contains(".hidden/") == false)
        write("A")
        try wait { session.directoryCompletion?.candidates == ["Alpha/", "Another/"] }
        write("\u{1b}[98~")
        try wait { session.directoryCompletion?.selectedIndex == 1 }
        write("\u{1b}[99~")
        try wait { session.snapshot().dump().contains("cd Another/") }
        try wait { session.directoryCompletion?.candidates == ["Child/"] }
        write("\u{1b}[99~")
        try wait { session.snapshot().dump().contains("cd Another/Child/") }
        try wait { session.directoryCompletion?.candidates == ["Grandchild/"] }
        write("\u{1b}[99~")
        try wait { session.snapshot().dump().contains("cd Another/Child/Grandchild/") }
        #expect(session.commandRecords.records.compactMap(\.exitStatus).isEmpty)
        write("\r")
        try wait { session.currentDirectory?.hasSuffix("/Another/Child/Grandchild") == true }
        write("cd ../../..\r")
        try wait { session.currentDirectory?.hasSuffix(home.lastPathComponent) == true }
        // Names a shell would split, quote or read as an option.
        for (typed, name) in [("空", "空格 中文"), ("quote", "quote'name"), ("-d", "-dash")] {
            write("cd \(typed)")
            try wait { session.directoryCompletion?.candidates == ["\(name)/"] }
            write("\u{1b}[99~\r")
            try wait { session.currentDirectory?.hasSuffix("/\(name)") == true }
            write("cd ..\r")
            try wait { session.currentDirectory?.hasSuffix(home.lastPathComponent) == true }
        }
        #expect(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8) == "PS1='READY> '\n")
    }
    /// macOS's /etc/zshrc sets HISTFILE from ZDOTDIR while ZDOTDIR still
    /// names the startup folder, so history was written there and deleted
    /// with it. The user's own choice of HISTFILE is kept.
    @Test(arguments: [nil, "custom_history"]) func historyStaysInTheUsersDirectory(chosen: String?) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("corta-histfile-test-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        let seen = home.appendingPathComponent("seen")
        // In .zshrc, as on any Mac: /etc/zshrc overrides an earlier choice.
        let choice = chosen.map { "HISTFILE='\(home.appendingPathComponent($0).path)'\n" } ?? ""
        try (choice + "print -r -- $HISTFILE > '\(seen.path)'\n")
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let prepared = ZshBootstrap.prepare(
            ["HOME": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
            executable: "/bin/zsh", arguments: ["-l"])
        let env = prepared.environment, made = prepared.folder
        let folder = try #require(made)
        defer { ZshBootstrap.remove(folder) }
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 30, columns: 100), workingDirectory: home.path)
        defer { session.stop() }
        session.start()
        let end = SuspendingClock.now + .seconds(5 * Double(testTimeoutScale))
        func reported() -> String? { try? String(contentsOf: seen, encoding: .utf8) }
        while reported()?.hasSuffix("\n") != true && SuspendingClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
        let histfile = try #require(reported(), "Startup did not finish: \(session.snapshot().dump())")
        // A system without /etc/zshrc's HISTFILE line sets none; that is fine.
        if chosen == nil, histfile == "\n" { return }
        #expect(histfile == home.appendingPathComponent(chosen ?? ".zsh_history").path + "\n")
    }

    @Test(arguments: [false, true]) func startupPreservesUserDotDirectory(explicit: Bool) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("corta-zdotdir-test-\(UUID().uuidString)")
        let dot = home.appendingPathComponent("dot")
        try fileManager.createDirectory(at: dot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        let seen = home.appendingPathComponent("seen")
        let order = home.appendingPathComponent("order")
        try "print -r -- ${+ZDOTDIR} > '\(seen.path)'\nZDOTDIR='\(dot.path)'\n".write(
            to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        for (file, marker) in [(".zprofile", "profile"), (".zshrc", "rc"), (".zlogin", "login")] {
            try "print -r -- \(marker) >> '\(order.path)'\n".write(
                to: dot.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        var original = [
            "HOME": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "TERM_PROGRAM": "Corta",
        ]
        if explicit { original["ZDOTDIR"] = home.path }
        let env = ZshBootstrap.environment(original, executable: "/bin/zsh", arguments: ["-l"])
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 30, columns: 100), workingDirectory: home.path)
        defer { session.stop() }
        session.start()
        // Startup-file preservation is complete when .zlogin writes its marker;
        // the prompt protocol is covered by shellOwnsFilteringAndAcceptance.
        let end = SuspendingClock.now + .seconds(5 * Double(testTimeoutScale))
        func startupFinished() -> Bool {
            (try? String(contentsOf: order, encoding: .utf8))?.hasSuffix("login\n") == true
        }
        while !startupFinished() && SuspendingClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
        try #require(startupFinished(), "Startup did not finish: \(session.snapshot().dump())")
        #expect(try String(contentsOf: seen, encoding: .utf8) == (explicit ? "1\n" : "0\n"))
        #expect(try String(contentsOf: order, encoding: .utf8) == "profile\nrc\nlogin\n")
    }

}
