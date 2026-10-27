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
import Carbon.HIToolbox
import Testing
import Synchronization
@testable import Corta

/// The intents are exercised against programmatic window controllers — an
/// `NSWindow` with a plain view controller, tracked by the delegate exactly
/// as a terminal window is — rather than by opening real terminal
/// windows. A terminal window brings a Metal layer, a first present and a
/// spawned shell with it, and on the hosted CI runner that held the main
/// thread for long enough to time out every other main-actor suite in the
/// run (the same starvation PR #76 closed for the teardown tests). What
/// these tests are about — identity, listing, focus, refusal — needs none
/// of that; `WindowSetupStagingTests` covers the root pane's spawn inputs
/// without a window at all.
@MainActor
struct AppIntentTests {
    private var delegate: AppDelegate {
        get throws { try #require(NSApp.delegate as? AppDelegate) }
    }

    /// A tracked terminal window controller with no terminal in it.
    private func makeTrackedWindow(title: String = "") throws -> TerminalWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let controller = TerminalWindowController(window: window)
        controller.contentViewController = NSViewController()
        try delegate.track(controller)
        return controller
    }

    @Test("a folder parameter must be an existing directory; nothing means home")
    func directoryValidation() throws {
        #expect(try OpenTerminalWindowIntent.validatedDirectory(nil) == nil)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(try OpenTerminalWindowIntent.validatedDirectory(tmp) == tmp.standardizedFileURL.path)
        let file = tmp.appendingPathComponent("corta-intent-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CortaIntentError.self) {
            try OpenTerminalWindowIntent.validatedDirectory(file)
        }
        #expect(throws: CortaIntentError.self) {
            try OpenTerminalWindowIntent.validatedDirectory(URL(string: "https://example.com")!)
        }
    }

    @Test("the intent checks its folder off the main thread, with the same answers")
    func directoryValidationOffMain() async throws {
        #expect(try await OpenTerminalWindowIntent.validatedDirectoryOffMain(nil) == nil)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(
            try await OpenTerminalWindowIntent.validatedDirectoryOffMain(tmp)
                == tmp.standardizedFileURL.path)
        await #expect(throws: CortaIntentError.self) {
            _ = try await OpenTerminalWindowIntent.validatedDirectoryOffMain(
                URL(string: "https://example.com")!)
        }
    }

    @Test("focusing an id no window carries fails rather than picking another window")
    func unknownIdIsRefused() throws {
        #expect(try delegate.focusWindow(id: "no-such-window") == false)
    }

    @Test("a tracked window is listed by identity, titled for display, and focusable by id")
    func listAndFocus() throws {
        let delegate = try delegate
        let controller = try makeTrackedWindow(title: "build — zsh")
        defer { controller.window?.close() }
        let listed = TerminalWindowQuery.openWindows()
        let entity = try #require(listed.first { $0.id == controller.windowID })
        #expect(entity.title == "build — zsh")
        #expect(Set(listed.map(\.id)).count == listed.count, "ids must be unique across windows")
        #expect(delegate.focusWindow(id: controller.windowID))
        // Frontmost among the app's windows. Not `isKeyWindow`: a test host
        // that is not the active application cannot make any window key.
        #expect(NSApp.orderedWindows.first === controller.window)
    }

    @Test("an untitled window is presented as Corta, never as an empty row")
    func emptyTitleFallsBack() throws {
        let controller = try makeTrackedWindow(title: "")
        defer { controller.window?.close() }
        #expect(TerminalWindowEntity(controller: controller).title == "Corta")
    }

    @Test("a closed window leaves the listing, so its id resolves to nothing")
    func closedWindowIsGone() throws {
        let controller = try makeTrackedWindow()
        let id = controller.windowID
        controller.window?.close()
        #expect(!TerminalWindowQuery.openWindows().contains { $0.id == id })
        #expect(try delegate.focusWindow(id: id) == false)
    }

    @Test("the Quick Terminal is not an entity: it is summoned, not arranged")
    func quickTerminalIsNotListed() throws {
        let controller = try makeTrackedWindow()
        defer { controller.window?.close() }
        controller.isQuickTerminal = true
        #expect(!TerminalWindowQuery.openWindows().contains { $0.id == controller.windowID })
        #expect(controller.restorableState == nil, "the panel is never saved into the arrangement")
    }
}
