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
import CortaPOSIX
import CortaSFTP
import CortaTerminal
import Darwin
import Testing

@testable import Corta

/// Whose a copy is decides when it goes. Scratch roots stand in for
/// `DroppedFiles`, with `.owner` records written as a process would write them.
@MainActor
struct FileDropCleanupTests {
    fileprivate func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Corta-Drop-Cleanup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A directory as another process would have left it.
    fileprivate func directory(_ name: String, in root: URL, owner: String?) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let files = FileDropStorage.destination(in: directory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("copy".utf8).write(to: files.appendingPathComponent("copy"))
        if let owner { try PrivateFile.write(Data(owner.utf8), to: directory.appendingPathComponent(".owner")) }
        return directory
    }

    fileprivate func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A pid nothing has: a child that has exited and been reaped.
    fileprivate func deadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test("an owner record reads as this run, a live sibling, or nobody")
    func ownerRecords() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let made = try FileDropStorage.makeDirectory(in: root)
        let mine = try String(contentsOf: made.appendingPathComponent(".owner"), encoding: .utf8)
        #expect(FileDropStorage.owner(fromRecord: mine) == .thisRun)
        // An earlier run with this pid, and an older version's bare pid.
        #expect(FileDropStorage.owner(fromRecord: "\(getpid()) another-launch") == .gone)
        #expect(FileDropStorage.owner(fromRecord: "\(getpid())") == .gone)
        #expect(FileDropStorage.owner(fromRecord: "\(getppid()) a-sibling") == .otherLive)
        #expect(FileDropStorage.owner(fromRecord: "\(try deadPid()) a-crash") == .gone)
        #expect(FileDropStorage.owner(fromRecord: "\(try deadPid())") == .gone)
        for broken in [nil, "", "not-a-pid", "-1", "0"] { #expect(FileDropStorage.owner(fromRecord: broken) == .gone) }
    }

    @Test("a launch removes what earlier runs left, and skips owners still alive")
    func launchCleanup() async throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let dead = try deadPid()
        let crashed = try directory("crashed", in: root, owner: "\(dead) old-launch")
        let oldVersion = try directory("old-version", in: root, owner: "\(dead)")
        try Data().write(to: oldVersion.appendingPathComponent(".published"))
        let sibling = try directory("sibling", in: root, owner: "\(getppid()) other-launch")
        let interrupted = root.appendingPathComponent(".removing-interrupted")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        let current = try FileDropStorage.makeDirectory(in: root)

        FileDropStorage.pruneAbandoned(in: root)

        for gone in [crashed, oldVersion, interrupted] { #expect(!exists(gone), "\(gone.lastPathComponent)") }
        #expect(exists(sibling))
        #expect(exists(current), "this run's own copies are not an earlier run's")
        await waitUntil("only the kept two remain") {
            Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                == [sibling.lastPathComponent, current.lastPathComponent]
        }
    }

    @Test("a directory just made by a live sibling, not yet recorded, is left alone")
    func unrecordedDirectory() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let young = try directory("young", in: root, owner: nil)
        FileDropStorage.pruneAbandoned(in: root)
        #expect(exists(young))
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: young.path)
        FileDropStorage.pruneAbandoned(in: root)
        #expect(!exists(young))
    }

    @Test("removal follows no link: what it points at stays, and a linked root is refused")
    func linksAreNotFollowed() async throws {
        let outside = try scratchRoot()
        defer { FileDropStorage.remove(outside) }
        let precious = outside.appendingPathComponent("precious")
        try Data("mine".utf8).write(to: precious)
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let crashed = try directory("crashed", in: root, owner: "\(try deadPid())")
        try FileManager.default.createSymbolicLink(
            at: FileDropStorage.destination(in: crashed).appendingPathComponent("link"), withDestinationURL: outside)
        // A forged record pointing out of the directory is not read through.
        let forged = try directory("forged", in: root, owner: nil)
        try FileManager.default.createSymbolicLink(
            at: forged.appendingPathComponent(".owner"), withDestinationURL: precious)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: forged.path)
        FileDropStorage.pruneAbandoned(in: root)
        await waitUntil("both are gone") { !exists(crashed) && !exists(forged) }
        try await Task.sleep(for: .milliseconds(100), clock: .suspending)
        #expect(try String(contentsOf: precious, encoding: .utf8) == "mine")

        let linkedParent = try scratchRoot()
        defer { FileDropStorage.remove(linkedParent) }
        let linkedRoot = linkedParent.appendingPathComponent("linked")
        let real = try directory("real", in: outside, owner: "\(try deadPid())")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        FileDropStorage.pruneAbandoned(in: linkedRoot)
        FileDropStorage.removeThisRun(in: [linkedRoot], timeout: 0.2)
        FileDropStorage.removeUnpinned(in: [linkedRoot])
        #expect(FileDropStorage.usage(in: [linkedRoot]) == 0)
        #expect(exists(real) && exists(precious))
        #expect(throws: (any Error).self) { try FileDropStorage.makeDirectory(in: linkedRoot) }
    }

    @Test("a quit removes this run's copies at once, and only this run's")
    func quitRemovesThisRun() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let mine = try FileDropStorage.makeDirectory(in: root)
        let sibling = try directory("sibling", in: root, owner: "\(getppid()) other-launch")
        FileDropStorage.removeThisRun(in: [root])
        #expect(!exists(mine))
        #expect(exists(sibling))
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)) == [sibling.lastPathComponent],
            "synchronous: nothing is left for the exit to cut short")
    }

    @Test("a quit gives up at its time limit rather than holding the exit")
    func quitIsBounded() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let start = SuspendingClock.now
        FileDropStorage.removeThisRun(in: [root], timeout: 0)
        #expect(SuspendingClock.now - start < .seconds(1))
    }

    @Test("Clean Now keeps what is being received and a live sibling's, and takes the rest")
    func cleanNow() async throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let receiving = try FileDropStorage.makeDirectory(in: root)
        let handedOut = try FileDropStorage.makeDirectory(in: root)
        FileDropStorage.release(handedOut)
        let sibling = try directory("sibling", in: root, owner: "\(getppid()) other-launch")
        let crashed = try directory("crashed", in: root, owner: "\(try deadPid())")
        FileDropStorage.removeUnpinned(in: [root])
        #expect(exists(receiving))
        #expect(exists(sibling))
        #expect(!exists(handedOut))
        #expect(!exists(crashed))
    }

    @Test("usage counts files under the roots and does not follow a link")
    func usageCounts() throws {
        let outside = try scratchRoot()
        defer { FileDropStorage.remove(outside) }
        try Data(count: 1 << 20).write(to: outside.appendingPathComponent("big"))
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        #expect(FileDropStorage.usage(in: [root]) == 0)
        #expect(FileDropStorage.usage(in: [root.appendingPathComponent("missing")]) == 0)
        let made = try FileDropStorage.makeDirectory(in: root)
        let files = FileDropStorage.destination(in: made)
        try Data(count: 64 << 10).write(to: files.appendingPathComponent("copy"))
        try FileManager.default.createSymbolicLink(
            at: files.appendingPathComponent("link"), withDestinationURL: outside)
        let bytes = FileDropStorage.usage(in: [root])
        #expect(bytes >= 64 << 10)
        #expect(bytes < 1 << 20)
    }

    @Test("the root is excluded from backups, from the first copy and at launch")
    func excludedFromBackup() throws {
        let parent = try scratchRoot()
        defer { FileDropStorage.remove(parent) }
        let root = parent.appendingPathComponent("drops", isDirectory: true)
        _ = try FileDropStorage.makeDirectory(in: root)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let older = parent.appendingPathComponent("older", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        FileDropStorage.pruneAbandoned(in: older)
        #expect(try older.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("cleaning up starts no process and arms no timer")
    func noLastingWork() throws {
        // A source rule: a count of child processes races the suites beside this.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Corta/TerminalView/FileDropStorage.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for word in ["Process(", "posix_spawn", "Timer", "launchctl", "asyncAfter", "Task.sleep"] {
            #expect(!text.contains(word), "\(word)")
        }
    }

    @Test("the old shared drag folder loses what has sat a day, and nothing younger")
    func legacyDragStaging() throws {
        let temporary = try scratchRoot()
        defer { FileDropStorage.remove(temporary) }
        let legacy = temporary.appendingPathComponent("Corta-SFTP-Drag", isDirectory: true)
        let old = legacy.appendingPathComponent("old"), young = legacy.appendingPathComponent("young")
        for folder in [old, young] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 86400)], ofItemAtPath: old.path)
        FileDropStorage.removeLegacyDragStaging(in: temporary)
        #expect(!exists(old))
        #expect(exists(young))
        try FileManager.default.removeItem(at: young)
        FileDropStorage.removeLegacyDragStaging(in: temporary)
    }

}

// MARK: - A pane's copies

extension FileDropCleanupTests {
    private func host(rootedAt root: URL) throws -> (CommandsTestHost, TerminalSession) {
        let host = CommandsTestHost()
        host.terminalView = TerminalView(frame: .zero)
        let session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), size: TerminalSize(rows: 10, columns: 60),
            workingDirectory: "/")
        session.start()
        host.session = session
        return (host, session)
    }

    @Test("closing a pane removes its own copies and no other pane's")
    func closingAPane() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let (first, firstSession) = try host(rootedAt: root)
        let (second, secondSession) = try host(rootedAt: root)
        defer { firstSession.stop(); secondSession.stop() }
        func drop(on host: CommandsTestHost) throws -> URL {
            let directory = try FileDropStorage.makeDirectory(in: root)
            let file = FileDropStorage.destination(in: directory).appendingPathComponent("copy")
            try Data().write(to: file)
            host.commands.completeFileDrop(.init(urls: [file], directory: directory, failed: false, timedOut: false),
                context: try #require(host.commands.dropInputContext))
            return directory
        }
        let mine = try drop(on: first), theirs = try drop(on: second)
        #expect(first.commands.droppedCopies == [mine])
        #expect(exists(mine) && exists(theirs))
        first.commands.stop()
        #expect(!exists(mine))
        #expect(exists(theirs))
    }

    /// AppKit resolves this app's pasteboard promises on the way out. A dragged
    /// SFTP row's was one nobody could keep: ⌘Q never returned.
    @Test("asking to quit lets go of a promise on the drag pasteboard")
    func quitDropsDragPromises() {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.setString("promise", forType: .string)
        #expect(AppDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("a user's own dropped file is used where it is and survives the pane")
    func originalsStay() throws {
        let root = try scratchRoot()
        defer { FileDropStorage.remove(root) }
        let original = root.appendingPathComponent("original")
        try Data("mine".utf8).write(to: original)
        let (host, session) = try host(rootedAt: root)
        defer { session.stop() }
        host.commands.completeFileDrop(.init(urls: [original], directory: nil, failed: false, timedOut: false),
            context: try #require(host.commands.dropInputContext))
        #expect(host.commands.droppedCopies.isEmpty)
        host.commands.stop()
        #expect(try String(contentsOf: original, encoding: .utf8) == "mine")
    }

    // MARK: - Settings

    @Test("Local Data shows the space in the background, and Clean Now gives it back")
    func settingsRow() async throws {
        let directory = try FileDropStorage.makeDirectory()
        defer { FileDropStorage.remove(directory) }
        try Data(count: 1 << 20).write(
            to: FileDropStorage.destination(in: directory).appendingPathComponent("copy"))
        let model = SettingsModel()
        model.refreshDroppedCopiesStatus()
        #expect(model.droppedCopiesStatus.message == L10n.text("settings.status.droppedCopiesMeasuring"),
            "the page draws before the walk finishes")
        await waitUntil("measured") { model.droppedCopiesStatus.actionTitle != nil }
        #expect(model.droppedCopiesStatus.actionTitle == L10n.text("settings.action.cleanNow"))
        #expect(exists(directory), "being received: only Clean Now's walk decides, and it has not run")
        FileDropStorage.release(directory)
        model.cleanDroppedCopies()
        await waitUntil("cleaned") { !exists(directory) }
        await waitUntil("re-measured") {
            model.droppedCopiesStatus.message != L10n.text("settings.status.droppedCopiesMeasuring")
        }
    }

    @Test("Local Data is found by search and writes nothing to the config file")
    func settingsSearchAndStore() {
        #expect(SettingsView.Category.privacy.matches("dropped"))
        #expect(SettingsView.Category.privacy.matches("local data"))
        let before = ConfigurationStore.shared.configuration
        let model = SettingsModel()
        model.refreshDroppedCopiesStatus()
        #expect(ConfigurationStore.shared.configuration == before)
    }
}
