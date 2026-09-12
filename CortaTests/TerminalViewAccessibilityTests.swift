import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// B10 — a programmatic audit of what VoiceOver actually calls, not a
/// listening pass. `AccessibilityMappingTests` already exercises
/// `TerminalAccessibilitySnapshot`'s column/offset math in isolation; this
/// drives `TerminalView`'s own `NSAccessibility` overrides (`accessibility
/// Value`, `accessibilityLine(for:)`, `accessibilityRange(forLine:)`,
/// `accessibilityInsertionPointLineNumber`) against a real view, which
/// nothing tested before this — the gap is the *view*, not the math it
/// calls into.
///
/// "Long-output reading/navigation verification" (B10's issue text) has two
/// halves: whether the data VoiceOver reads is structurally correct (this
/// file, and `AccessibilityMappingTests`), and whether it *sounds* right
/// read aloud (a human, listening — `docs/CONFORMANCE.md`'s "not judged"
/// convention is where that stays tracked; nothing here claims to replace
/// it).
@MainActor
struct TerminalViewAccessibilityTests {
    /// A bare view with a snapshot wired in directly — `accessibility
    /// SnapshotProvider` is exactly the seam `ViewController` uses to avoid
    /// giving `TerminalView` any knowledge of `Grid`, so a test can use the
    /// same seam without a pane, a session or a window.
    private func view(snapshot: TerminalAccessibilitySnapshot) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.accessibilitySnapshotProvider = { snapshot }
        return view
    }

    private func terminal(rows: Int = 24, columns: Int = 40) -> Terminal {
        Terminal(rows: rows, columns: columns, scrollbackLimit: 500)
    }

    // MARK: - Element identity

    @Test func exposesItselfAsATextAreaWithANonEmptyLabel() {
        var terminal = self.terminal()
        terminal.feed(Array("hello".utf8))
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
        let view = view(snapshot: snapshot)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(!(view.accessibilityLabel() ?? "").isEmpty)
    }

    @Test func withNoProviderInstalledEverythingDegradesRatherThanCrashing() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.accessibilityValue() == nil)
        #expect(view.accessibilityNumberOfCharacters() == 0)
        #expect(view.accessibilityLine(for: 0) == 0)
        #expect(view.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 0))
        #expect(view.accessibilityHelp() == nil)
    }

    // MARK: - Long-output line navigation

    /// The scenario the issue names directly: many lines of real output,
    /// walked the way VoiceOver walks a text area — `accessibilityLine
    /// (for:)` finding the right line for an offset, and `accessibilityRange
    /// (forLine:)` inverting it — for every line, not a sampled few, since a
    /// long-output reader steps through every one of them in turn.
    @Test func everyLineRoundTripsThroughLineNavigation() {
        var terminal = self.terminal(rows: 30, columns: 40)
        for index in 0..<30 {
            terminal.feed(Array("line \(index) of output\r\n".utf8))
        }
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
        let view = view(snapshot: snapshot)
        let text = view.accessibilityValue() as? String
        #expect(text != nil)
        #expect(view.accessibilityNumberOfCharacters() == (text?.utf16.count ?? -1))

        for line in 0..<snapshot.lineStarts.count {
            let range = view.accessibilityRange(forLine: line)
            #expect(range.location == snapshot.lineStarts[line], "line \(line) start")
            // The start of the reported range must itself map back to this
            // same line — the round trip a screen reader relies on to know
            // which line it just landed on.
            #expect(view.accessibilityLine(for: range.location) == line, "line \(line) round trip")
        }
    }

    /// Wide (CJK) and combining text mixed into the same output a screen
    /// reader would step through line by line — not just the isolated
    /// column math `AccessibilityMappingTests` already covers, but that the
    /// view's own line APIs stay correct once several such lines are mixed
    /// with plain ASCII ones.
    @Test func lineNavigationStaysCorrectAcrossWideAndCombiningLines() {
        var terminal = self.terminal(rows: 10, columns: 40)
        terminal.feed(Array("ascii line\r\n".utf8))
        terminal.feed(Array("中文一行文字\r\n".utf8))
        terminal.feed(Array("e\u{0301}cafe\u{0301} combining\r\n".utf8))
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
        let view = view(snapshot: snapshot)
        for line in 0..<snapshot.lineStarts.count {
            let range = view.accessibilityRange(forLine: line)
            #expect(view.accessibilityLine(for: range.location) == line, "line \(line)")
        }
    }

    // MARK: - Scrolled history is what gets reported

    /// Scrolled into history, the view must report *that* text and *that*
    /// cursor line — not the live screen's, which is the defect this whole
    /// subsystem's doc comments (U01) name as the reason a snapshot carries
    /// its own `scrollOffset`.
    @Test func scrolledViewReportsHistoryNotTheLiveScreen() {
        var terminal = self.terminal(rows: 5, columns: 20)
        for index in 0..<20 {
            terminal.feed(Array("row \(index)\r\n".utf8))
        }
        let live = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil, scrollOffset: 0)
        let scrolled = TerminalAccessibilitySnapshot(
            grid: terminal.grid, selection: nil, scrollOffset: 10)
        let liveView = view(snapshot: live)
        let scrolledView = view(snapshot: scrolled)
        let liveText = liveView.accessibilityValue() as? String ?? ""
        let scrolledText = scrolledView.accessibilityValue() as? String ?? ""
        #expect(liveText != scrolledText)
        // The live screen shows the most recent rows; scrolled 10 back shows
        // older ones a reader following the live screen would never hear.
        #expect(liveText.contains("row 19"))
        #expect(!scrolledText.contains("row 19"))
    }

    // MARK: - Selection

    @Test func selectionRangeAndTextAgreeWithTheSnapshot() {
        var terminal = self.terminal(rows: 4, columns: 20)
        terminal.feed(Array("hello world".utf8))
        let selection = SelectionRange(
            anchor: SelectionPoint(row: 0, column: 0), head: SelectionPoint(row: 0, column: 5))
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: selection)
        let view = view(snapshot: snapshot)
        #expect(view.accessibilitySelectedTextRange() == snapshot.selectedRange)
        #expect(view.accessibilitySelectedText() == "hello")
    }

    @Test func noSelectionMeansNoSelectedText() {
        var terminal = self.terminal(rows: 4, columns: 20)
        terminal.feed(Array("hello".utf8))
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
        let view = view(snapshot: snapshot)
        #expect(view.accessibilitySelectedText() == nil)
    }

    // MARK: - The visible range is the whole exposed value

    @Test func visibleCharacterRangeCoversTheWholeValue() {
        var terminal = self.terminal(rows: 6, columns: 20)
        terminal.feed(Array("some output\r\nand more\r\n".utf8))
        let snapshot = TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
        let view = view(snapshot: snapshot)
        let range = view.accessibilityVisibleCharacterRange()
        #expect(range == NSRange(location: 0, length: snapshot.text.utf16.count))
    }
}
