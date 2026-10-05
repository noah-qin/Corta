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
@testable import CortaTerminal

/// A pane as search sees it: a view for the bar and a grid fed directly,
/// so what is searched is exactly what the test printed — no shell, no
/// echo of the typed command, no renderer.
@MainActor
final class SearchTestHost: PaneSearchHost {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    var terminalView: TerminalView! = nil
    var topInset: CGFloat = 0
    var scrollOffset = 0
    var terminal = Terminal(rows: 10, columns: 60)
    var selection: String?
    private(set) var redraws = 0
    /// Owned here, as a pane owns its search; the search holds its host weakly.
    private(set) lazy var search = PaneSearch(host: self)

    func snapshot() -> Grid? { terminal.grid }
    func selectedText() -> String? { selection }
    func invalidateDisplay() { redraws += 1 }

    /// Lines as a program would print them.
    func print(_ text: String) {
        terminal.feed(Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }
}

/// The keystroke search path: the sweep is debounced, runs off the
/// main thread, a newer query supersedes the one in flight, and closing the
/// bar cancels it — against `PaneSearch` alone.
@MainActor
@Suite(.serialized)
struct PaneSearchTests {
    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds * Double(testTimeoutScale))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A host holding `P04MARKER`.
    private func makeHost() -> SearchTestHost {
        let host = SearchTestHost()
        host.print("P04MARKER\n")
        return host
    }

    @Test func keystrokeSearchDebouncesThenDelivers() async throws {
        let host = makeHost()
        defer { host.search.close() }

        host.search.show()
        let field = try #require(host.search.field)
        field.stringValue = "P04MARKER"
        host.search.updateResults(scrollsToMatch: true)
        // Debounced and detached: nothing can have landed on the same
        // main-actor turn that scheduled the sweep.
        #expect(host.search.matches.isEmpty)
        #expect(host.search.task != nil)

        #expect(await waitUpTo(5) { !host.search.matches.isEmpty })
        #expect(host.search.task == nil)
        #expect(host.redraws > 0)
    }

    @Test func aNewerQuerySupersedesTheInFlightSweep() async throws {
        let host = makeHost()
        defer { host.search.close() }

        host.search.show()
        let field = try #require(host.search.field)
        field.stringValue = "P04MARKER"
        host.search.updateResults(scrollsToMatch: true)
        // Retyped before the debounce elapses: the first sweep is cancelled
        // in its sleep and only the newest query may land.
        field.stringValue = "zzz-no-such-string"
        host.search.updateResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { host.search.task == nil })
        #expect(host.search.matches.isEmpty)
    }

    @Test func closingTheBarCancelsTheInFlightSweep() throws {
        let host = makeHost()

        host.search.show()
        let field = try #require(host.search.field)
        field.stringValue = "P04MARKER"
        host.search.updateResults(scrollsToMatch: true)
        #expect(host.search.task != nil)

        host.search.close()
        #expect(host.search.task == nil)
        #expect(host.search.matches.isEmpty)
    }

    /// `NSEvent.addLocalMonitorForEvents` fires app-wide, so without a window
    /// check an Esc meant for one pane's search bar would close every open bar
    /// in the app. Two panes, two windows, two open bars — an Esc tagged to
    /// window A must close only A's bar and must not be swallowed for B.
    @Test func escapeOnlyClosesTheSearchBarInItsOwnWindow() throws {
        func makeWindowedHost() -> (SearchTestHost, NSWindow) {
            let host = makeHost()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host.view
            return (host, window)
        }

        let (hostA, windowA) = makeWindowedHost()
        let (hostB, windowB) = makeWindowedHost()
        defer {
            hostA.search.close()
            hostB.search.close()
            withExtendedLifetime(windowB) {}
        }
        hostA.search.show()
        hostB.search.show()
        #expect(hostA.search.bar != nil)
        #expect(hostB.search.bar != nil)

        let escapeForA = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: windowA.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: 53)!

        #expect(hostA.search.handleGlobalEscape(escapeForA) == nil)
        #expect(hostA.search.bar == nil)
        #expect(hostB.search.bar != nil)

        // B's monitor sees the same event and must let it pass through
        // unmodified — it belongs to a different window.
        #expect(hostB.search.handleGlobalEscape(escapeForA) === escapeForA)
        #expect(hostB.search.bar != nil)
    }

    /// A split puts two panes in *one* window, so the window check alone is
    /// not enough to tell their bars apart — an Esc typed while one pane's
    /// search field is focused must close only that pane's bar, not its
    /// sibling's.
    @Test func escapeOnlyClosesTheSearchBarOfTheFocusedPaneInASplit() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostA = makeHost()
        let hostB = makeHost()
        hostB.view.frame.origin.x = 600
        window.contentView?.addSubview(hostA.view)
        window.contentView?.addSubview(hostB.view)
        defer {
            hostA.search.close()
            hostB.search.close()
        }
        hostA.search.show()
        hostB.search.show()
        #expect(hostA.search.bar != nil)
        #expect(hostB.search.bar != nil)

        // `show` already focused B's field last; refocus A's so the event
        // under test targets a deliberate, known first responder.
        window.makeFirstResponder(hostA.search.field)

        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: 53)!

        // A's own monitor, with A's field focused, closes A only.
        #expect(hostA.search.handleGlobalEscape(escape) == nil)
        #expect(hostA.search.bar == nil)
        #expect(hostB.search.bar != nil)

        // B's monitor saw the same event (both fire app-wide) but must let
        // it pass through: the focused field belongs to A, not B.
        #expect(hostB.search.handleGlobalEscape(escape) === escape)
        #expect(hostB.search.bar != nil)
    }

    /// Case-sensitivity read live from `ConfigurationStore` on every sweep
    /// would let toggling it in one pane silently change what a second,
    /// already-open pane's *next* sweep matches. Each pane's sweep
    /// must use only its own local flag.
    @Test func caseSensitivityIsIsolatedPerPane() async throws {
        let hostA = SearchTestHost()
        let hostB = SearchTestHost()
        defer {
            hostA.search.close()
            hostB.search.close()
        }
        hostA.print("Hello hello\n")
        hostB.print("Hello hello\n")

        hostA.search.show()
        hostB.search.show()
        // Set explicitly rather than relying on whatever the config file
        // defaults to: what this proves is that setting one pane's copy
        // never touches the other's.
        hostA.search.caseSensitive = true
        hostB.search.caseSensitive = false

        try #require(hostA.search.field).stringValue = "hello"
        hostA.search.updateResults(scrollsToMatch: true)
        try #require(hostB.search.field).stringValue = "hello"
        hostB.search.updateResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { hostA.search.task == nil && hostB.search.task == nil })
        #expect(hostA.search.matches.count == 1)
        #expect(hostB.search.matches.count == 2)
    }

    /// `regex` is a separate local flag from `caseSensitive` with its own
    /// toggle and sweep branch (`PaneSearch.sweep`) — isolating one says
    /// nothing about the other, so it needs its own proof.
    @Test func regexModeIsIsolatedPerPane() async throws {
        let hostA = SearchTestHost()
        let hostB = SearchTestHost()
        defer {
            hostA.search.close()
            hostB.search.close()
        }
        hostA.print("abc123 abc456\n")
        hostB.print("abc123 abc456\n")

        hostA.search.show()
        hostB.search.show()
        hostA.search.regex = true
        hostB.search.regex = false

        // A pattern that matches as a regex but appears nowhere as a
        // literal substring: A must find the digit runs, B must find
        // nothing, for the identical query string.
        try #require(hostA.search.field).stringValue = "[0-9]+"
        hostA.search.updateResults(scrollsToMatch: true)
        try #require(hostB.search.field).stringValue = "[0-9]+"
        hostB.search.updateResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { hostA.search.task == nil && hostB.search.task == nil })
        #expect(hostA.search.matches.count == 2, "regex-on A must match both digit runs")
        #expect(
            hostB.search.matches.isEmpty,
            "literal-mode B must not match \"[0-9]+\" as a substring — if it shared A's regex flag it would")
    }

    /// Output arriving while a sweep is already running must not be silently
    /// dropped — a `scheduleBackgroundRefresh` that is a no-op whenever a
    /// sweep is in flight, with nothing re-triggering one once it finishes,
    /// would drop it. The gate holds a sweep open deterministically so the
    /// race is exercised on purpose rather than hoped for.
    @Test func outputArrivingMidSweepIsCaughtUpAfterwards() async throws {
        let host = makeHost()
        defer { host.search.close() }
        host.search.show()
        // Not on screen yet: finding it at all proves the follow-up sweep
        // saw the output that arrived mid-sweep.
        try #require(host.search.field).stringValue = "MARKER2"

        let releaseFirstSweep = Mutex(false)
        let firstSweepEntered = Mutex(false)
        host.search.sweepGate = {
            firstSweepEntered.withLock { $0 = true }
            while !releaseFirstSweep.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
        }

        host.search.scheduleBackgroundRefresh()
        #expect(await waitUpTo(5) { firstSweepEntered.withLock { $0 } })
        #expect(host.search.task != nil, "precondition: the first sweep is parked in the gate")

        // A second output batch arrives while the first sweep is still
        // running — this call must set `needsRefresh`, not drop it.
        host.print("MARKER2\n")
        host.search.scheduleBackgroundRefresh()
        #expect(host.search.needsRefresh, "the output that arrived mid-sweep must not be dropped")

        host.search.sweepGate = nil  // the follow-up sweep must not park too
        releaseFirstSweep.withLock { $0 = true }

        #expect(
            await waitUpTo(10) { host.search.task == nil && !host.search.matches.isEmpty },
            "expected a follow-up sweep to catch the output the in-flight one missed")
    }

    /// The pre-search offset is a raw distance-from-bottom count; restoring
    /// it verbatim after output grew the scrollback while the bar was open
    /// lands the viewport on different text than what was on screen before
    /// search opened. The restore must shift by the growth, the same way a
    /// selection's `baseScrollbackTotal` does.
    @Test func closingSearchRestoresThePreSearchLineNotJustTheRawOffset() throws {
        let host = makeHost()
        host.print((1...100).map { "filler \($0)\n" }.joined())
        host.scrollOffset = 1
        host.search.show()
        #expect(host.search.previousScrollOffset == 1)
        let totalPushedAtOpen = try #require(host.search.previousTotalPushed)

        host.print((1...50).map { "more \($0)\n" }.joined())
        let growth = try #require(host.snapshot()).scrollback.totalPushed - totalPushedAtOpen
        #expect(growth == 50, "precondition: the scrollback grew by what was printed")

        host.search.close()
        #expect(host.scrollOffset == 1 + growth)
    }

    /// Zero is not a document position that drifts with output — it *is*
    /// "follow the live bottom". A user who opened search already at the
    /// bottom must still be at the bottom on close, not scrolled up into
    /// history by however much arrived while the bar was open.
    @Test func closingSearchAtTheBottomStaysAtTheBottomDespiteOutputWhileOpen() throws {
        let host = makeHost()
        host.search.show()
        #expect(host.search.previousScrollOffset == 0)

        host.print((1...200).map { "filler \($0)\n" }.joined())
        #expect(try #require(host.snapshot()).scrollback.totalPushed > 0)

        host.search.close()
        #expect(host.scrollOffset == 0, "expected to stay at the bottom, not shift into history")
    }

    /// ⌘E takes the selection's first line as the query.
    @Test func useSelectionForFindTakesTheFirstLine() async throws {
        let host = makeHost()
        defer { host.search.close() }
        host.selection = "P04MARKER\nsecond line"
        host.search.useSelectionForFind()
        #expect(host.search.field?.stringValue == "P04MARKER")
        #expect(await waitUpTo(5) { !host.search.matches.isEmpty })
    }

    @Test("a stale or closed search cannot change its successor's status")
    func staleStatusIsDiscarded() {
        let orphan = PaneSearch()
        orphan.bar = NSGlassEffectView()
        orphan.generation = 2
        orphan.status = .invalidPattern
        orphan.applyResults(.init(matches: [], status: .complete),
            generation: 1, scrollsToMatch: false, totalPushed: 0)
        #expect(orphan.status == .invalidPattern)
        orphan.bar = nil
        orphan.applyResults(.init(matches: [], status: .patternTooSlow),
            generation: 2, scrollsToMatch: false, totalPushed: 0)
        #expect(orphan.status == .invalidPattern)
    }
}

/// The pane hands the Find menu to its search: the menu items name
/// `performFindPanelAction:`, which only `PaneSearch` implements.
@MainActor
struct PaneSearchRoutingTests {
    @Test func theFindActionReachesThePanesSearch() {
        let pane = ViewController()
        let action = #selector(PaneSearch.performFindPanelAction(_:))
        #expect(!pane.responds(to: action))
        #expect(pane.supplementalTarget(forAction: action, sender: nil) as AnyObject === pane.search)
    }
}
