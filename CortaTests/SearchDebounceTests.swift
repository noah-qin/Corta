import AppKit
import Synchronization
import Testing

@testable import Corta
@testable import CortaTerminal

/// P04 — the keystroke search path: the sweep is debounced, runs off the
/// main thread, a newer query supersedes the one in flight, and closing the
/// bar cancels it. Real panes with real children, like
/// `PaneTeardownTests` — the content under search comes from the shell
/// itself, so the whole path (PTY → grid → snapshot → sweep → apply) is
/// exercised rather than a mock of it.
@MainActor
@Suite(.serialized)
struct SearchDebounceTests {
    /// Loads the pane's view, which builds the renderer and spawns the child
    /// exactly as a window would.
    private func makePane() -> ViewController {
        let pane = ViewController()
        _ = pane.view
        return pane
    }

    @MainActor
    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func gridContains(_ pane: ViewController, _ needle: String) -> Bool {
        pane.session.snapshot().logicalLines().contains { $0.text.contains(needle) }
    }

    private func makePaneWithMarker() async throws -> ViewController {
        let pane = makePane()
        let session = try #require(pane.session)
        session.write(Array("echo P04MARKER\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "P04MARKER") })
        return pane
    }

    @Test func keystrokeSearchDebouncesThenDelivers() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        // Debounced and detached: nothing can have landed on the same
        // main-actor turn that scheduled the sweep.
        #expect(pane.searchMatches.isEmpty)
        #expect(pane.searchTask != nil)

        #expect(await waitUpTo(5) { !pane.searchMatches.isEmpty })
        #expect(pane.searchTask == nil)
    }

    @Test func aNewerQuerySupersedesTheInFlightSweep() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        // Retyped before the debounce elapses: the first sweep is cancelled
        // in its sleep and only the newest query may land.
        field.stringValue = "zzz-no-such-string"
        pane.updateSearchResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { pane.searchTask == nil })
        #expect(pane.searchMatches.isEmpty)
    }

    @Test func closingTheBarCancelsTheInFlightSweep() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        #expect(pane.searchTask != nil)

        pane.closeSearchBar()
        #expect(pane.searchTask == nil)
        #expect(pane.searchMatches.isEmpty)
    }

    /// B02: `NSEvent.addLocalMonitorForEvents` fires app-wide, so without a
    /// window check an Esc meant for one pane's search bar closed every open
    /// bar in the app. Two panes, two windows, two open bars — an Esc tagged
    /// to window A must close only A's bar and must not be swallowed for B.
    @Test func escapeOnlyClosesTheSearchBarInItsOwnWindow() throws {
        func makeWindowedPane() -> ViewController {
            let pane = makePane()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = pane
            return pane
        }

        let paneA = makeWindowedPane()
        let paneB = makeWindowedPane()
        defer {
            paneA.teardown()
            paneB.teardown()
        }
        paneA.showSearchBar()
        paneB.showSearchBar()
        #expect(paneA.searchBar != nil)
        #expect(paneB.searchBar != nil)

        let escapeForA = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: try #require(paneA.view.window).windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: 53)!

        let unhandledByA = paneA.handleGlobalSearchEscape(escapeForA)
        #expect(unhandledByA == nil)
        #expect(paneA.searchBar == nil)
        #expect(paneB.searchBar != nil)

        // B's monitor must see the same event and let it pass through
        // unmodified — it belongs to a different window.
        let unhandledByB = paneB.handleGlobalSearchEscape(escapeForA)
        #expect(unhandledByB === escapeForA)
        #expect(paneB.searchBar != nil)
    }

    /// B05: a split puts two panes in *one* window, so the window check
    /// alone (B02's fix) is not enough to tell their bars apart — an Esc
    /// typed while one pane's search field is focused must close only that
    /// pane's bar, not its sibling's.
    @Test func escapeOnlyClosesTheSearchBarOfTheFocusedPaneInASplit() throws {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        split.splitFocusedPane(orientation: .columns)
        defer { split.teardown() }

        let panes = split.panes
        #expect(panes.count == 2)
        let paneA = panes[0]
        let paneB = panes[1]
        paneA.showSearchBar()
        paneB.showSearchBar()
        #expect(paneA.searchBar != nil)
        #expect(paneB.searchBar != nil)

        // `showSearchBar` already focused B's field last; refocus A's so the
        // event under test targets a deliberate, known first responder.
        window.makeFirstResponder(paneA.searchField)

        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: 53)!

        // A's own monitor, with A's field focused, closes A only.
        #expect(paneA.handleGlobalSearchEscape(escape) == nil)
        #expect(paneA.searchBar == nil)
        #expect(paneB.searchBar != nil)

        // B's monitor saw the same event (both fire app-wide) but must let
        // it pass through: the focused field belongs to A, not B.
        #expect(paneB.handleGlobalSearchEscape(escape) === escape)
        #expect(paneB.searchBar != nil)
    }

    /// B05: case-sensitivity used to be read live from `ConfigurationStore`
    /// on every sweep, so toggling it in one pane silently changed what a
    /// second, already-open pane's *next* sweep matched. Each pane's sweep
    /// must use only its own local flag.
    @Test func caseSensitivityIsIsolatedPerPane() async throws {
        let paneA = makePane()
        let paneB = makePane()
        defer {
            paneA.teardown()
            paneB.teardown()
        }
        for pane in [paneA, paneB] {
            let session = try #require(pane.session)
            session.write(Array("echo Hello hello\n".utf8))
            #expect(await waitUpTo(10) { self.gridContains(pane, "Hello hello") })
        }

        paneA.showSearchBar()
        paneB.showSearchBar()
        // Set explicitly rather than relying on whatever the real machine's
        // config file happens to default to (never assume machine state) —
        // what this test verifies is that setting one pane's copy never
        // touches the other's, not what any particular default is.
        paneA.searchCaseSensitive = true
        paneB.searchCaseSensitive = false

        try #require(paneA.searchField).stringValue = "hello"
        paneA.updateSearchResults(scrollsToMatch: true)
        try #require(paneB.searchField).stringValue = "hello"
        paneB.updateSearchResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { paneA.searchTask == nil })
        #expect(await waitUpTo(5) { paneB.searchTask == nil })
        // Exact counts depend on shell echo specifics (the typed command
        // line itself contains the query too); what this test is actually
        // proving is that the two panes' sweeps disagree at all — if they
        // shared one flag (the pre-B05 bug), both counts would be equal.
        #expect(paneA.searchMatches.count > 0)
        #expect(
            paneB.searchMatches.count > paneA.searchMatches.count,
            "case-insensitive B must find strictly more than case-sensitive A for the same text")
    }

    /// B05: `searchRegex` is a separate local flag from `searchCaseSensitive`
    /// with its own toggle and sweep branch (`Self.sweep`) — isolating one
    /// says nothing about the other, so it needs its own proof.
    @Test func regexModeIsIsolatedPerPane() async throws {
        let paneA = makePane()
        let paneB = makePane()
        defer {
            paneA.teardown()
            paneB.teardown()
        }
        for pane in [paneA, paneB] {
            let session = try #require(pane.session)
            session.write(Array("printf 'abc123 abc456\\n'\n".utf8))
            #expect(await waitUpTo(10) { self.gridContains(pane, "abc123 abc456") })
        }

        paneA.showSearchBar()
        paneB.showSearchBar()
        paneA.searchRegex = true
        paneB.searchRegex = false

        // A pattern that matches as a regex but appears nowhere as a
        // literal substring: A must find the digit runs, B must find
        // nothing, for the identical query string.
        try #require(paneA.searchField).stringValue = "[0-9]+"
        paneA.updateSearchResults(scrollsToMatch: true)
        try #require(paneB.searchField).stringValue = "[0-9]+"
        paneB.updateSearchResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { paneA.searchTask == nil })
        #expect(await waitUpTo(5) { paneB.searchTask == nil })
        #expect(paneA.searchMatches.count > 0, "regex-on A must match the digit runs")
        #expect(
            paneB.searchMatches.isEmpty,
            "literal-mode B must not match \"[0-9]+\" as a substring — if it shared A's regex flag it would")
    }

    /// B05: output arriving while a sweep is already running used to be
    /// silently dropped — `scheduleBackgroundSearchRefresh` was a no-op
    /// whenever `searchTask != nil`, and nothing re-triggered a sweep once
    /// the in-flight one finished. The gate lets the test hold a sweep open
    /// deterministically so the race is exercised on purpose rather than
    /// hoped for.
    @Test func outputArrivingMidSweepIsCaughtUpAfterwards() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }
        pane.showSearchBar()
        // Not "MARKER": the first (P04MARKER) is already on screen when the
        // gate parks the first sweep, and "MARKER2" doesn't exist yet — so
        // finding it at all is unambiguous proof the follow-up sweep saw
        // the output that arrived mid-sweep, with no risk of the shell's
        // own command-line echo doubling an already-nonzero count.
        try #require(pane.searchField).stringValue = "MARKER2"

        let releaseFirstSweep = Mutex(false)
        let firstSweepEntered = Mutex(false)
        pane.searchSweepGate = {
            firstSweepEntered.withLock { $0 = true }
            while !releaseFirstSweep.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
        }

        pane.scheduleBackgroundSearchRefresh()
        #expect(await waitUpTo(5) { firstSweepEntered.withLock { $0 } })
        #expect(pane.searchTask != nil, "precondition: the first sweep is parked in the gate")

        // A second output batch arrives while the first sweep is still
        // running — this call must set `searchNeedsRefresh`, not drop it.
        // Assembled by the shell (`$((1+1))`), not typed literally: the
        // terminal's own echo of the command *as typed* would otherwise
        // make "MARKER2" appear on screen from the input line alone, before
        // the output this test is actually waiting for ever printed.
        pane.session.write(Array("echo MARKER$((1+1))\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "MARKER2") })
        pane.scheduleBackgroundSearchRefresh()
        #expect(pane.searchNeedsRefresh, "the output that arrived mid-sweep must not be dropped")

        pane.searchSweepGate = nil  // the follow-up sweep must not park too
        releaseFirstSweep.withLock { $0 = true }

        // The follow-up sweep this triggers picks up MARKER2 once it lands.
        #expect(
            await waitUpTo(10) {
                pane.searchTask == nil && !pane.searchMatches.isEmpty
            },
            "expected a follow-up sweep to catch the output the in-flight one missed")
    }

    /// B05: `scrollOffsetBeforeSearch` is a raw distance-from-bottom count;
    /// restoring it verbatim after output grew the scrollback while the bar
    /// was open lands the viewport on different text than what was on
    /// screen before search opened. The restore must shift by the growth,
    /// the same way a selection's `baseScrollbackTotal` does.
    @Test func closingSearchRestoresThePreSearchLineNotJustTheRawOffset() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }
        // Push some real history first — `scrollOffset` cannot legitimately
        // exceed `scrollback.count`, so setting it to 1 while the ring is
        // still empty (as it is right after `makePaneWithMarker`, whose
        // two lines have not yet scrolled off screen) is not a state a real
        // user's scroll gesture could produce, and the restore's own
        // `min(scrollback.count, …)` safety clamp (correctly) refuses to
        // honor it.
        pane.session.write(Array("yes filler | head -n 100\n".utf8))
        #expect(
            await waitUpTo(10) { pane.session.snapshot().scrollback.totalPushed > 0 })
        // Scroll up one line before opening search, so there is a non-zero
        // offset to restore.
        pane.scrollOffset = 1
        pane.showSearchBar()
        #expect(pane.scrollOffsetBeforeSearch == 1)
        let totalPushedAtOpen = try #require(pane.totalPushedBeforeSearch)

        // Output arrives while the bar is open — exactly what
        // `scheduleBackgroundSearchRefresh` exists to keep results current
        // against.
        // The completion marker is assembled by the shell (`$((1+1))`),
        // not typed literally — the terminal's local echo of the command
        // *as typed* would otherwise make a literal marker appear on
        // screen immediately, long before the flood in front of it has
        // actually run, which is exactly what raced here the first time.
        pane.session.write(Array("yes filler | head -n 2000; echo DONE_FLOOD$((1+1))ING\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "DONE_FLOOD2ING") })
        let totalPushedNow = try #require(pane.session).snapshot().scrollback.totalPushed
        #expect(totalPushedNow > totalPushedAtOpen, "precondition: the scrollback actually grew")

        pane.closeSearchBar()

        // A lower bound, not exact equality: the shell prints a fresh
        // prompt line immediately after `DONE_FLOOD2ING` finishes, which
        // can itself push one more line into scrollback in the gap between
        // the measurement above and `closeSearchBar`'s own — real, and not
        // what this test is about. What matters is that the restore is
        // nowhere near the raw, unshifted `1` a pre-B05 restore would have
        // produced, and does scale with the real growth rather than being
        // some other fixed, drifted number.
        let growth = totalPushedNow - totalPushedAtOpen
        #expect(
            pane.scrollOffset >= 1 + growth && pane.scrollOffset <= 1 + growth + 4,
            "expected the restore to shift by roughly the growth since capture (\(growth)), not replay the raw 1 — got \(pane.scrollOffset)")
    }
}
