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
import Synchronization
import Testing
@testable import Corta

/// A folder named from Finder's service, `open -a` or the Dock is checked
/// before a window opens in it, off the main thread and bounded; what
/// passes reaches the window as a spawn directory and nothing else.
@MainActor
struct FolderRequestTests {
    /// A scratch folder holding a folder, a file and links to each.
    private struct Fixture {
        let root: URL
        var folder: URL { root.appendingPathComponent("folder", isDirectory: true) }
        var file: URL { root.appendingPathComponent("file.txt") }
        var folderLink: URL { root.appendingPathComponent("folder-link") }
        var fileLink: URL { root.appendingPathComponent("file-link") }
        var locked: URL { root.appendingPathComponent("locked", isDirectory: true) }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("corta-folder-request-\(UUID().uuidString)", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
            try manager.createSymbolicLink(
                at: root.appendingPathComponent("folder-link"),
                withDestinationURL: root.appendingPathComponent("folder"))
            try manager.createSymbolicLink(
                at: root.appendingPathComponent("file-link"),
                withDestinationURL: root.appendingPathComponent("file.txt"))
            try manager.createDirectory(at: root.appendingPathComponent("locked"), withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("locked").path)
        }

        func remove() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("a folder opens; a file, a missing path, an unreadable folder and a web URL are refused")
    func theCheck() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.folder.standardizedFileURL.path
        #expect(FolderRequest.check(fixture.folder) == .success(folder))
        #expect(FolderRequest.check(fixture.file) == .failure(.notFolder(fixture.file.standardizedFileURL.path)))
        let missing = fixture.root.appendingPathComponent("missing")
        #expect(FolderRequest.check(missing) == .failure(.missing(missing.standardizedFileURL.path)))
        #expect(FolderRequest.check(fixture.locked) == .failure(.unreadable(fixture.locked.standardizedFileURL.path)))
        let web = try #require(URL(string: "https://example.com/folder"))
        #expect(FolderRequest.check(web) == .failure(.notLocal("https://example.com/folder")))
    }

    @Test("a link to a folder opens under the name it was given; a link to a file is refused")
    func symbolicLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.folderLink.standardizedFileURL.path
        #expect(FolderRequest.check(fixture.folderLink) == .success(link))
        #expect(
            FolderRequest.check(fixture.fileLink)
                == .failure(.notFolder(fixture.fileLink.standardizedFileURL.path)))
    }

    @Test("the checks run off the main thread and answer on it, in the order asked")
    func checksRunOffMain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let onMain = Mutex(false)
        let outcomes = await withCheckedContinuation { continuation in
            FolderRequest.check(
                [fixture.file, fixture.folder],
                check: { url in
                    if Thread.isMainThread { onMain.withLock { $0 = true } }
                    return FolderRequest.check(url)
                },
                then: { outcomes in
                    MainActor.assertIsolated()
                    continuation.resume(returning: outcomes)
                })
        }
        #expect(onMain.withLock { $0 } == false, "a check ran on the main thread")
        #expect(outcomes == [
            .failure(.notFolder(fixture.file.standardizedFileURL.path)),
            .success(fixture.folder.standardizedFileURL.path),
        ])
    }

    @Test("a check that does not answer in time is refused, and does not hold the others")
    func aHungCheckIsBounded() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let hung = URL(fileURLWithPath: "/Volumes/gone/project", isDirectory: true)
        let ready = URL(fileURLWithPath: "/tmp/ready", isDirectory: true)
        // Timed where the waiting happens, off the main actor: the answer's
        // trip back to a busy main actor is not what the deadline bounds.
        let (outcomes, elapsed) = await Task.detached {
            let clock = SuspendingClock()
            let start = clock.now
            let outcomes = FolderRequest.checkWaiting(
                [hung, ready], timeout: .seconds(1), budget: PathProbe.Budget(limit: 4),
                check: { url in
                    if url == hung { release.wait() }
                    return .success(url.path)
                })
            return (outcomes, clock.now - start)
        }.value
        #expect(elapsed < .seconds(10), "the deadline is 1 s; waited \(elapsed)")
        #expect(outcomes == [.failure(.noAnswer("/Volumes/gone/project")), .success("/tmp/ready")])
    }

    @Test("past the probe budget a path is refused unchecked")
    func budgetExhausted() {
        let budget = PathProbe.Budget(limit: 0)
        let checked = Mutex(0)
        let outcomes = FolderRequest.checkWaiting(
            [URL(fileURLWithPath: NSTemporaryDirectory())], timeout: .milliseconds(50), budget: budget,
            check: { url in
                checked.withLock { $0 += 1 }
                return FolderRequest.check(url)
            })
        #expect(checked.withLock { $0 } == 0)
        #expect(outcomes == [.failure(.noAnswer(URL(fileURLWithPath: NSTemporaryDirectory()).path))])
    }

    @Test("a folder's window carries its directory and nothing else for the child")
    func folderSetupIsADirectoryOnly() {
        let setup = AppDelegate.folderWindowSetup("/tmp/project")
        #expect(setup.workingDirectory == "/tmp/project")
        #expect(setup.directoriesChecked)
        #expect(setup.restore == nil)
        #expect(setup.preset == nil)
        #expect(setup.adopting == nil)
    }

    /// The window is born in the folder: its root pane spawns there, by
    /// initializer, as a ⌘N window's does — the same staging
    /// `WindowSetupStagingTests` checks, so the child gets one winsize.
    @Test("a folder's root pane spawns in the folder; its splits are checked afresh")
    func folderReachesRootPane() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.path
        let split = SplitViewController(setup: AppDelegate.folderWindowSetup(directory))
        _ = split.view
        defer { split.teardown() }
        let pane = try #require(split.panes.first)
        #expect(pane.inheritedWorkingDirectory == directory)
        #expect(pane.preset == nil)
        // The check was the root pane's (spent at its spawn); a later split
        // opens where the user is, and checks that itself.
        #expect(!split.setup.directoriesChecked)
    }

    @Test("a service reads file URLs from its pasteboard, never text")
    func servicePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noahqin.Corta.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("/tmp; rm -rf ~", forType: .string)
        #expect(AppDelegate.fileURLs(on: pasteboard).isEmpty)

        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        #expect(AppDelegate.fileURLs(on: pasteboard).map(\.standardizedFileURL) == [folder.standardizedFileURL])
    }

    @Test("each refusal says why, a paragraph each, and an over-long request says how many were skipped")
    func refusalText() {
        let text = AppDelegate.refusalText(
            [.missing("/tmp/a"), .notFolder("/tmp/b"), .unreadable("/tmp/c"), .noAnswer("/tmp/d"),
             .notLocal("https://example.com")],
            excess: 3)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 6)
        for name in ["/tmp/a", "/tmp/b", "/tmp/c", "/tmp/d", "https://example.com"] {
            #expect(text.contains(name))
        }
        #expect(lines.last?.contains("\(FolderRequest.maximumFolders)") == true)
        #expect(lines.last?.contains("3") == true)
    }
}
