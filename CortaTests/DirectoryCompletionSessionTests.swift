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
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("corta-stale-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent(ZshBootstrap.folderPrefix + "old")
        let fresh = root.appendingPathComponent(ZshBootstrap.folderPrefix + "fresh")
        let other = root.appendingPathComponent("someone-else")
        for url in [old, fresh, other] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let now = Date()
        let dayAgo = now.addingTimeInterval(-ZshBootstrap.staleAge - 60)
        try fm.setAttributes([.modificationDate: dayAgo], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: dayAgo], ofItemAtPath: other.path)
        ZshBootstrap.removeStaleFolders(in: root, now: now)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path), "the other build may be starting a shell from it")
        #expect(fm.fileExists(atPath: other.path))
    }

    @Test func shellOwnsFilteringAndAcceptance() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("corta-cd-session-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        for name in ["Alpha", "Another", "空格 中文", "quote'name", ".hidden", "-dash"] {
            try fm.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: home.appendingPathComponent("Linked"), withDestinationURL: home.appendingPathComponent("Alpha"))
        try "not a directory".write(to: home.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try "PS1='READY> '\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let env = ZshBootstrap.environment(["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "TERM_PROGRAM": "Corta"], executable: "/bin/zsh", arguments: ["-l"])
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 40, columns: 120), workingDirectory: home.path)
        defer { session.stop() }
        session.start()
        func wait(_ predicate: () -> Bool) throws {
            let end = Date().addingTimeInterval(5 * Double(testTimeoutScale))
            while Date() < end {
                if predicate() { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(Bool(false), "\(session.snapshot().dump())")
        }
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
        #expect(session.commandRecords.records.compactMap(\.exitStatus).isEmpty)
        write("\r")
        try wait { session.currentDirectory?.hasSuffix("/Another") == true }
        write("cd ..\r")
        try wait { session.currentDirectory?.hasSuffix(home.lastPathComponent) == true }
        write("cd 空")
        try wait { session.directoryCompletion?.candidates == ["空格 中文/"] }
        write("\u{1b}[99~\r")
        try wait { session.currentDirectory?.hasSuffix("/空格 中文") == true }
        write("cd ..\r")
        try wait { session.currentDirectory?.hasSuffix(home.lastPathComponent) == true }
        write("cd quote")
        try wait { session.directoryCompletion?.candidates == ["quote'name/"] }
        write("\u{1b}[99~\r")
        try wait { session.currentDirectory?.hasSuffix("/quote'name") == true }
        write("cd ..\r")
        try wait { session.currentDirectory?.hasSuffix(home.lastPathComponent) == true }
        write("cd -d")
        try wait { session.directoryCompletion?.candidates == ["-dash/"] }
        write("\u{1b}[99~\r")
        try wait { session.currentDirectory?.hasSuffix("/-dash") == true }
        #expect(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8) == "PS1='READY> '\n")
    }
    @Test(arguments: [false, true]) func startupPreservesUserDotDirectory(explicit: Bool) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("corta-zdotdir-test-\(UUID().uuidString)")
        let dot = home.appendingPathComponent("dot")
        try fm.createDirectory(at: dot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let seen = home.appendingPathComponent("seen")
        let order = home.appendingPathComponent("order")
        try "print -r -- ${+ZDOTDIR} > '\(seen.path)'\nZDOTDIR='\(dot.path)'\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        for (file, marker) in [(".zprofile", "profile"), (".zshrc", "rc"), (".zlogin", "login")] {
            try "print -r -- \(marker) >> '\(order.path)'\n".write(to: dot.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        var original = ["HOME": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "TERM_PROGRAM": "Corta"]
        if explicit { original["ZDOTDIR"] = home.path }
        let env = ZshBootstrap.environment(original, executable: "/bin/zsh", arguments: ["-l"])
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 30, columns: 100), workingDirectory: home.path)
        defer { session.stop() }
        session.start()
        // Startup-file preservation is complete when .zlogin writes its marker;
        // the prompt protocol is covered by shellOwnsFilteringAndAcceptance.
        let end = Date().addingTimeInterval(5 * Double(testTimeoutScale))
        func startupFinished() -> Bool {
            (try? String(contentsOf: order, encoding: .utf8))?.hasSuffix("login\n") == true
        }
        while !startupFinished() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        try #require(startupFinished(), "Startup did not finish: \(session.snapshot().dump())")
        #expect(try String(contentsOf: seen, encoding: .utf8) == (explicit ? "1\n" : "0\n"))
        #expect(try String(contentsOf: order, encoding: .utf8) == "profile\nrc\nlogin\n")
    }

}
