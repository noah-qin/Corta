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
import Darwin
import Foundation
import Synchronization
import Testing

@testable import Corta

/// What a launch checks before its first window, and what a crash leaves behind.
struct SessionLaunchTests {
    // MARK: - Launch, and what a crash leaves

    @Test("the launch's directory check answers on the main actor, without holding it")
    @MainActor func directoryCheckDoesNotHoldTheMainActor() async {
        let released = Mutex(false)
        let answered = Mutex<Set<String>?>(nil)
        PathProbe.directories(
            among: ["/fast", "/hung"], timeout: .milliseconds(100),
            isDirectory: { path in
                if path == "/fast" { return true }
                while !released.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.005) }
                return true
            }, budget: PathProbe.Budget(limit: 4),
            then: { found in answered.withLock { $0 = found } })
        // Reached with the check still blocked: nothing waited here.
        #expect(answered.withLock { $0 } == nil)
        let done = await waitUntilTrue(timeout: .seconds(5)) { answered.withLock { $0 } != nil }
        #expect(done)
        #expect(answered.withLock { $0 } == ["/fast"], "what did not answer counts as absent")
        released.withLock { $0 = true }
    }

    /// A directory checked a moment ago is not waited on again: the spawn goes
    /// straight to it, and only a real failure falls back.
    @Test("a pane told its directory was checked spawns there without a second check")
    @MainActor func checkedDirectoryIsNotCheckedAgain() throws {
        let missing = "/nonexistent-\(UUID().uuidString)"
        func start(checked: Bool) throws -> PaneSpawn.Started {
            try PaneSpawn.start(
                size: TerminalSize(rows: 10, columns: 40), directory: missing, directoryChecked: checked,
                scrollbackLimit: 100, configuredShell: "/bin/sh",
                directoryCompletion: false, historySuggestions: false)
        }
        let unchecked = try start(checked: false)
        unchecked.session.stop()
        // Its own check found nothing, so it never tried to go there.
        #expect(unchecked.notice == nil)
        let checked = try start(checked: true)
        checked.session.stop()
        #expect(checked.notice == L10n.text("failure.notice.fallbackDirectory"), "went there on the word it was given")
    }

    @Test("the restore marker and a state file's directory are owner-only")
    @MainActor func markerIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)/nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = SessionRestore(directory: directory)
        store.beginRestore()
        #expect(store.previousRestoreFailed)
        let file = try FileManager.default.attributesOfItem(atPath: store.markerURL.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test("reading a state file tightens what an older build left")
    func readingTightensPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try Data("[]".utf8).write(to: url)
        chmod(url.path, 0o644)
        #expect(try PrivateFile.read(url) == Data("[]".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // A link is no state file of ours, and nothing is read through it.
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try PrivateFile.read(link) }
    }

    @Test("an old temporary from a dead save goes; everything else stays")
    func abandonedTemporariesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func touch(_ name: String, age: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
            return url
        }
        let uuid = UUID().uuidString
        let old = try touch(".state.json.\(uuid)", age: 3600)
        let recent = try touch(".recent-hosts.json.\(UUID().uuidString)", age: 10)
        let state = try touch("state.json", age: 3600)
        let hidden = try touch(".owner", age: 3600)
        let notOurs = try touch(".state.json.backup", age: 3600)
        PrivateFile.removeAbandonedTemporaries(in: directory, olderThan: AppPaths.abandonedStateFileAge)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for kept in [recent, state, hidden, notOurs] {
            #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
        }
    }
}

@MainActor
private func waitUntilTrue(timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout * testTimeoutScale
    while !condition(), SuspendingClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
}
