import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U12 — the four things scrollback search and the scrollback viewport were
/// not telling the user.
struct SearchStabilityTests {
    private static func ranges(atRows rows: [Int]) -> [SelectionRange] {
        rows.map {
            SelectionRange(
                anchor: SelectionPoint(row: $0, column: 0),
                head: SelectionPoint(row: $0, column: 3))
        }
    }

    /// **The defect this closes.** A match list is recomputed every time the
    /// child prints, and document rows are measured backwards from the live
    /// screen — so "match 7 of 12" is a different piece of text one line of
    /// output later. Keeping the *index* moved the highlight and the viewport
    /// somewhere else on every output batch; keeping the absolute row keeps
    /// the text.
    @Test("the current match survives output that renumbers every match")
    func currentMatchFollowsItsText() throws {
        // Three matches at absolute rows 100, 140, 180 with 200 lines pushed.
        let before = Self.ranges(atRows: [-100, -60, -20])
        let anchor = 200 + (-60)  // the middle one
        #expect(
            ViewController.index(closestTo: anchor, in: before, totalPushed: 200) == 1)

        // Ten lines of output later every document row has shifted by ten and
        // a new match has appeared *above* the others, so the index would now
        // name the wrong one.
        let after = Self.ranges(atRows: [-110, -70, -30, -5])
        #expect(
            ViewController.index(closestTo: anchor, in: after, totalPushed: 210) == 1)
        // The naive answer — keep the number — would have been match 1 in a
        // list where the text at index 1 is a different line.
        #expect(after[1].start.row == -70)
        #expect(210 + after[1].start.row == anchor)
    }

    /// The anchored line can be evicted from the scrollback or overwritten by
    /// the program. Landing on the nearest surviving match is what a person
    /// reading down a log expects; losing the place entirely is not.
    @Test("a vanished anchor lands on the nearest match")
    func nearestWhenTheAnchorIsGone() {
        let matches = Self.ranges(atRows: [-100, -50, -10])
        #expect(ViewController.index(closestTo: 1000 - 52, in: matches, totalPushed: 1000) == 1)
        #expect(ViewController.index(closestTo: 1000 - 9, in: matches, totalPushed: 1000) == 2)
    }

    /// With no anchor the newest match wins, which is where a fresh search
    /// should start in a terminal — the bottom is the present.
    @Test("no anchor starts at the newest match")
    func noAnchorStartsAtTheEnd() {
        let matches = Self.ranges(atRows: [-100, -50, -10])
        #expect(ViewController.index(closestTo: nil, in: matches, totalPushed: 0) == 2)
        #expect(ViewController.index(closestTo: 5, in: [], totalPushed: 0) == nil)
    }

    // MARK: - Case sensitivity

    /// The core already took the flag; nothing in the UI ever set it. Both
    /// directions are asserted here so "the toggle is wired" is a fact, not
    /// an intention.
    @Test("case sensitivity changes what matches")
    func caseSensitivitySelectsDifferentMatches() {
        var terminal = Terminal(rows: 8, columns: 40, scrollbackLimit: 50)
        terminal.feed(Array("Error: one\r\nerror: two\r\nERROR: three\r\n".utf8))
        let grid = terminal.grid
        #expect(Search.find("error", in: grid, caseSensitive: false).count == 3)
        #expect(Search.find("error", in: grid, caseSensitive: true).count == 1)
        #expect(Search.find("Error", in: grid, caseSensitive: true).count == 1)
    }

    @Test("the setting round-trips through the config file")
    func caseSensitivityIsAConfigKey() {
        let (parsed, unknown) = Configuration.parse("search-case-sensitive = true")
        #expect(unknown.isEmpty)
        #expect(parsed.searchCaseSensitive)
        #expect(parsed.serialized().contains("search-case-sensitive = true"))
        // Off by default: a person searching a log for `error` wants `ERROR`.
        #expect(!Configuration().searchCaseSensitive)
    }
}

/// The scroll-position pill: what it says, and that it says it in words.
@MainActor
struct ScrollPositionIndicatorTests {
    @Test("it says how far back the viewport is") func reportsDistance() {
        let indicator = ScrollPositionIndicator()
        indicator.update(linesBack: 12340, hasNewOutput: false)
        let label = try! #require(indicator.accessibilityLabel())
        #expect(label.contains(ScrollPositionIndicator.formatted(12340)))
        #expect(!indicator.hasNewOutput)
    }

    /// New output changes the **words**, not only the tint — a colour-only
    /// signal is no signal to a reader who cannot separate the two colours,
    /// the same rule the failure panel follows.
    @Test("new output changes the words, not only the colour") func reportsNewOutput() {
        let indicator = ScrollPositionIndicator()
        indicator.update(linesBack: 40, hasNewOutput: false)
        let resting = try! #require(indicator.accessibilityLabel())
        indicator.update(linesBack: 40, hasNewOutput: true)
        let alerted = try! #require(indicator.accessibilityLabel())
        #expect(resting != alerted)
        #expect(alerted.contains(L10n.text("scrollback.newOutput")))
        #expect(indicator.hasNewOutput)
    }

    /// It is a button, and it says what pressing it does — the affordance is
    /// the whole point, so it has to be reachable without a pointer.
    @Test("it is a button that returns to the bottom") func actsAsAButton() {
        let indicator = ScrollPositionIndicator()
        var returned = false
        indicator.onReturnToBottom = { returned = true }
        indicator.update(linesBack: 5, hasNewOutput: false)
        #expect(indicator.accessibilityRole() == .button)
        #expect(indicator.accessibilityLabel()?.contains(
            L10n.text("scrollback.returnToBottom")) == true)
        #expect(indicator.accessibilityPerformPress())
        #expect(returned)
    }

    @Test("large counts are grouped for reading") func groupsDigits() {
        #expect(ScrollPositionIndicator.formatted(999) == "999")
        #expect(ScrollPositionIndicator.formatted(12340).contains(","))
    }
}
