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
import CortaTerminal
import Testing

@testable import Corta

/// The screens Corta shows when something it depends on is not there.
///
/// This is the one part of the app that has to work when the rest does not,
/// which is exactly why it is the part least likely to be exercised by hand:
/// reproducing "the login shell was uninstalled" or "the volume was
/// unmounted" on a working machine takes deliberate effort, and the panel is
/// invisible in every render test. The contract is asserted here instead.
@MainActor
@Suite(.serialized)
struct RecoveryUITests {
    // MARK: - The failure panel

    /// Failure is signalled by the symbol *and* the words. A red panel says
    /// nothing to a person who cannot separate red from grey, and this is the
    /// screen that has to stay readable when everything else is broken.
    @Test func theFailurePanelNamesTheFailureInWordsNotColour() {
        let view = PaneFailureView(
            title: "Could not start a shell", detail: "No such file or directory",
            canRetry: true)
        let label = try! #require(view.accessibilityLabel())
        #expect(label.contains("Could not start a shell"))
        #expect(label.contains("No such file or directory"))
        #expect(view.accessibilityRole() == .group)

        // The symbol is emphasis; the words carry the meaning, so the icon
        // itself is not read out.
        let icon = view.descendants(of: NSImageView.self).first
        #expect(icon?.isAccessibilityElement() == false)
    }

    /// The card's colours follow its own window's appearance. Read outside
    /// it, `windowBackgroundColor.cgColor` took the process's: a dark window
    /// got a white card under white text.
    @Test func thePanelFollowsItsWindowsAppearance() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = nil }
        let root = try #require(window.contentView)
        let failure = PaneFailureView(title: "t", detail: "d", canRetry: true)
        failure.present(in: root, takesFocus: false)
        root.layoutSubtreeIfNeeded()
        let panel = failure.overlay.panel
        // The glass follows on its own; the drawn edge is resolved here.
        #expect(panel.layer?.borderColor == NSColor(white: 1, alpha: 0.14).cgColor)
    }

    /// Settings… only where a setting could be the cause; a dropped
    /// connection is not one.
    @Test func settingsAreOfferedOnlyWhereTheyCouldHelp() {
        let runtime = PaneFailureView(
            title: "t", detail: "d", canRetry: false, canReconnect: true, showsSettings: false)
        let titles = runtime.descendants(of: NSButton.self).map(\.title)
        #expect(!titles.contains(L10n.text("failure.button.settings")))
        #expect(runtime.primaryAction?.title == L10n.text("failure.button.reconnect"))
    }

    /// Reconnect clears the output and opens a connection; a stray Return —
    /// typed into another pane, or at the dimmed output — must not do that.
    @Test func returnNeverReconnects() {
        let lost = PaneFailureView(
            title: "t", detail: "d", canRetry: false, canReconnect: true, showsSettings: false)
        #expect(lost.primaryAction?.title == L10n.text("failure.button.reconnect"))
        #expect(lost.primaryAction?.keyEquivalent == "")
    }

    /// Over a failed session the terminal may still have a live child whose
    /// output nobody reads: a click must not make it the key view.
    @Test func noClickReachesTheFailedPane() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let failure = PaneFailureView(
            title: "t", detail: "d", canRetry: true, showsSettings: false, backdrop: .dim)
        failure.present(in: root, takesFocus: false)
        root.layoutSubtreeIfNeeded()
        let corner = NSPoint(x: 4, y: 4)
        let hit = root.hitTest(corner)
        #expect(hit === failure)
    }

    /// The raw reason is there, but behind Details, not in the sentence.
    @Test func theRawReasonIsBehindDetails() throws {
        let view = PaneFailureView(title: "t", detail: "d", canRetry: true, details: "read: Input/output error")
        let panel = view.overlay.panel
        #expect(!panel.isShowingDetails)
        let toggle = try #require(panel.detailsToggle)
        toggle.performClick(nil)
        #expect(panel.isShowingDetails)
        let texts = view.descendants(of: NSTextField.self).map(\.stringValue)
        #expect(texts.contains("read: Input/output error"))
    }

    /// Try Again appears only where retrying can help — a Mac that reports no
    /// Metal device will not grow one while the app is running, and a button
    /// that cannot work is worse than no button.
    @Test func retryIsOfferedOnlyWhenRetryingCouldWork() {
        let retryable = PaneFailureView(title: "t", detail: "d", canRetry: true)
        let titles = retryable.descendants(of: NSButton.self).map(\.title)
        #expect(titles.count == 2)
        // The primary action is the rightmost, as in any Mac dialog.
        #expect(titles.last == L10n.text("failure.button.retry"))

        let terminal = PaneFailureView(title: "t", detail: "d", canRetry: false)
        let onlySettings = terminal.descendants(of: NSButton.self).map(\.title)
        #expect(onlySettings == [L10n.text("failure.button.settings")])
    }

    /// The panel takes keyboard focus itself, because the pane it replaced
    /// has no terminal view for `makeFirstResponder` to land on.
    @Test func thePanelOffersSomethingToFocus() {
        let retryable = PaneFailureView(title: "t", detail: "d", canRetry: true)
        #expect(retryable.primaryAction?.title == L10n.text("failure.button.retry"))
        // Return activates it, so the panel answers the key a person presses
        // without looking.
        #expect(retryable.primaryAction?.keyEquivalent == "\r")

        let terminal = PaneFailureView(title: "t", detail: "d", canRetry: false)
        #expect(terminal.primaryAction?.title == L10n.text("failure.button.settings"))
    }

    @Test func bothActionsAreWired() {
        let view = PaneFailureView(title: "t", detail: "d", canRetry: true)
        var retried = false
        var settings = false
        view.onRetry = { retried = true }
        view.onOpenSettings = { settings = true }
        let buttons = view.descendants(of: NSButton.self)
        for button in buttons {
            _ = button.target?.perform(button.action, with: button)
        }
        #expect(retried)
        #expect(settings)
    }

    // MARK: - What the panel says

    /// `PTYError` carries its own description; anything else falls back to
    /// Foundation's. The detail line is the only place the underlying reason
    /// reaches the user, so an empty or synthesized one is a dead end.
    @Test func everySpawnFailureDescribesItself() {
        let errors: [PTYError] = [
            .executablePathNotAbsolute,
            .spawnFailed(code: ENOENT),
            .spawnFailed(code: EACCES),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
            // Not the raw synthesized case name.
            #expect(!error.description.hasPrefix("spawnFailed("))
        }
    }

    // MARK: - Corrupt state

    /// A terminal that refuses to launch because its restore state is corrupt
    /// is worse than one that opens a fresh window. Truncated JSON, a
    /// wrong-shaped document and an empty file all read as "nothing to
    /// restore" rather than as an error.
    @Test func corruptRestoreStateReadsAsNothingToRestore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-recovery-\(UUID().uuidString)")
        let store = SessionRestore(directory: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for corrupt in ["", "{", "[{\"frame\":", "null", "{\"windows\":[]}"] {
            try corrupt.write(to: store.fileURL, atomically: true, encoding: .utf8)
            #expect(store.load().isEmpty, "\(corrupt.debugDescription) should not throw")
        }
    }
}

extension NSView {
    /// Every descendant of a kind, for asserting on a view built in code.
    fileprivate func descendants<T: NSView>(of kind: T.Type) -> [T] {
        subviews.flatMap { view in
            ((view as? T).map { [$0] } ?? []) + view.descendants(of: kind)
        }
    }
}
