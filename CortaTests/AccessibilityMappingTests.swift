import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U01 — the two conversions an assistive technology asks a terminal for, and
/// the one nothing else in the app has to get right.
///
/// `NSRange` counts UTF-16 code units; a grid counts columns. They agree only
/// for ASCII, and every VoiceOver step over CJK, an emoji or a combining mark
/// crosses the disagreement. These tests drive the mapping from a real
/// `Terminal` rather than a hand-built grid, so what is asserted is what the
/// parser actually produces for those inputs.
@MainActor
struct AccessibilityMappingTests {
    private static func terminal(_ rows: Int = 4, _ columns: Int = 20) -> Terminal {
        Terminal(rows: rows, columns: columns, scrollbackLimit: 100)
    }

    private static func snapshot(
        _ terminal: Terminal, selection: SelectionRange? = nil, scrollOffset: Int = 0
    ) -> TerminalAccessibilitySnapshot {
        TerminalAccessibilitySnapshot(
            grid: terminal.grid, selection: selection, scrollOffset: scrollOffset)
    }

    // MARK: - Column -> UTF-16

    /// The ASCII case, where offset and column happen to be equal — the
    /// coincidence the old code mistook for the rule.
    @Test func asciiColumnsAndOffsetsCoincide() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.offset(documentRow: 0, column: 0) == 0)
        #expect(snapshot.offset(documentRow: 0, column: 4) == 4)
        #expect(snapshot.cell(forOffset: 4) == (row: 0, column: 4))
    }

    /// CJK: two columns per character, one UTF-16 unit. Column 4 is the third
    /// character, which is offset 2 — the old `offset - lineStart` arithmetic
    /// answered 4, two characters into the wrong place.
    @Test func wideCharactersMapColumnsToTheirOwnCharacter() {
        var terminal = Self.terminal()
        terminal.feed(Array("中文测试".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.text.hasPrefix("中文测试"))
        #expect(snapshot.offset(documentRow: 0, column: 0) == 0)
        #expect(snapshot.offset(documentRow: 0, column: 2) == 1)
        #expect(snapshot.offset(documentRow: 0, column: 4) == 2)
        #expect(snapshot.offset(documentRow: 0, column: 6) == 3)
        // The inverse, including a column that is a wide character's second
        // cell: it belongs to that character, not to the next one.
        #expect(snapshot.cell(forOffset: 0) == (row: 0, column: 0))
        #expect(snapshot.cell(forOffset: 2) == (row: 0, column: 4))
    }

    /// An astral emoji is two columns *and* two UTF-16 units, so the two
    /// counts drift in the other direction from CJK. An offset inside the
    /// surrogate pair answers with the emoji's own cell rather than splitting
    /// it — half a surrogate pair is not a place VoiceOver can be.
    @Test func astralEmojiIsOneCellAcrossTwoUTF16Units() {
        var terminal = Self.terminal()
        terminal.feed(Array("a🙂b".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.offset(documentRow: 0, column: 0) == 0)
        #expect(snapshot.offset(documentRow: 0, column: 1) == 1)
        #expect(snapshot.cell(forOffset: 1) == (row: 0, column: 1))
        #expect(snapshot.cell(forOffset: 2) == (row: 0, column: 1))
        // "b" sits after the emoji's two columns.
        #expect(snapshot.offset(documentRow: 0, column: 3) == 3)
        #expect(snapshot.cell(forOffset: 3) == (row: 0, column: 3))
    }

    /// A combining mark adds UTF-16 units without adding a column, so offsets
    /// run ahead of columns on the same row.
    @Test func combiningMarksAddUnitsWithoutAddingColumns() {
        var terminal = Self.terminal()
        terminal.feed(Array("e\u{301}x".utf8))  // é as e + U+0301, then x
        let snapshot = Self.snapshot(terminal)
        // Two columns of content, but the first carries two UTF-16 units.
        #expect(snapshot.offset(documentRow: 0, column: 0) == 0)
        #expect(snapshot.offset(documentRow: 0, column: 1) == 2)
        #expect(snapshot.cell(forOffset: 1) == (row: 0, column: 0))
        #expect(snapshot.cell(forOffset: 2) == (row: 0, column: 1))
    }

    // MARK: - Rows

    @Test func offsetsAreRelativeToTheRowTheyAreOn() {
        var terminal = Self.terminal()
        terminal.feed(Array("ab\r\ncd".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.lineStarts[0] == 0)
        #expect(snapshot.lineStarts[1] == 3)  // "ab" + the newline
        #expect(snapshot.offset(documentRow: 1, column: 1) == 4)
        #expect(snapshot.cell(forOffset: 4) == (row: 1, column: 1))
    }

    /// A column past the row's trimmed tail clamps to the row's own end
    /// rather than running into the next line's text.
    @Test func aColumnPastTheTailClampsToItsRow() {
        var terminal = Self.terminal()
        terminal.feed(Array("ab\r\ncd".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.offset(documentRow: 0, column: 19) == 2)
    }

    // MARK: - The viewport, and the scroll offset

    /// Scrolled into the history, the snapshot is the history — and a
    /// document row still indexes into it, because the offset conversion
    /// applies the scroll itself.
    @Test func aScrolledSnapshotReadsTheHistory() {
        var terminal = Self.terminal(3, 20)
        for line in 0..<8 { terminal.feed(Array("line\(line)\r\n".utf8)) }
        let live = Self.snapshot(terminal)
        #expect(live.text.contains("line7"))
        #expect(!live.text.contains("line2"))

        let scrolled = Self.snapshot(terminal, scrollOffset: 4)
        #expect(scrolled.scrollOffset == 4)
        #expect(scrolled.text.contains("line3"))
        #expect(!scrolled.text.contains("line7"))
        // Document row -3 is visible row 1 at this offset.
        #expect(scrolled.offset(documentRow: -3, column: 0) == scrolled.lineStarts[1])
    }

    /// A selection anchored in the scrollback is reported as the part of it
    /// that is on screen, not dropped and not clamped to nothing.
    @Test func aSelectionFromTheScrollbackIsClippedToTheViewport() {
        var terminal = Self.terminal(3, 20)
        for line in 0..<8 { terminal.feed(Array("line\(line)\r\n".utf8)) }
        let grid = terminal.grid
        let selection = SelectionRange(
            anchor: SelectionPoint(row: -6, column: 0),
            head: SelectionPoint(row: 1, column: 2))
        let snapshot = TerminalAccessibilitySnapshot(
            grid: grid, selection: selection, scrollOffset: 0)
        #expect(snapshot.selectedRange.location == 0)
        #expect(snapshot.selectedRange.length > 0)
        #expect(snapshot.selectedRange.upperBound <= snapshot.text.utf16.count)
    }

    /// With no selection the range is an empty one at the insertion point,
    /// which is what a text area is expected to report.
    @Test func noSelectionReportsTheInsertionPoint() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.selectedRange == NSRange(location: snapshot.cursorOffset, length: 0))
        #expect(snapshot.cursorOffset == 5)
    }

    // MARK: - Screen coordinates

    /// `accessibilityRange(for:)` is handed a **screen** point. Converting it
    /// as if it were a window point put every answer off by the window's
    /// origin, which on a second display is thousands of points (U01).
    @Test func hitTestingConvertsFromScreenNotWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 500, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.cellSize = CGSize(width: 8, height: 17)
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds

        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let grid = terminal.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(grid: grid, selection: nil)
        }
        // A recording stand-in for the pane's real mapping: what matters is
        // which point it is handed, not what it makes of it.
        var received: CGPoint?
        view.cellAtPoint = { point in
            received = point
            return (column: 0, row: 0)
        }

        let viewPoint = CGPoint(x: 24, y: 34)
        let screenPoint = window.convertToScreen(
            NSRect(origin: view.convert(viewPoint, to: nil), size: .zero)
        ).origin
        _ = view.accessibilityRange(for: screenPoint)
        let got = try! #require(received)
        #expect(abs(got.x - viewPoint.x) < 0.5)
        #expect(abs(got.y - viewPoint.y) < 0.5)
    }

    /// Without a window there is no screen space to convert from, so the
    /// query has no answer rather than a wrong one.
    @Test func hitTestingWithoutAWindowHasNoAnswer() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let grid = terminal.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(grid: grid, selection: nil)
        }
        view.cellAtPoint = { _ in (column: 3, row: 0) }
        #expect(view.accessibilityRange(for: CGPoint(x: 10, y: 10)).length == 0)
        #expect(view.accessibilityRange(for: CGPoint(x: 10, y: 10)).location == 0)
    }

    /// The outline VoiceOver draws follows the range's real columns. On a CJK
    /// row a two-character range is four columns wide, not two.
    @Test func theFrameForARangeUsesRealColumns() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var terminal = Self.terminal()
        terminal.feed(Array("中文测试".utf8))
        let grid = terminal.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(grid: grid, selection: nil)
        }
        var asked: [(row: Int, column: Int)] = []
        view.accessibilityCellFrameProvider = { row, column in
            asked.append((row, column))
            return CGRect(x: CGFloat(column) * 8, y: CGFloat(row) * 17, width: 8, height: 17)
        }
        let frame = view.accessibilityFrame(for: NSRange(location: 0, length: 2))
        #expect(asked.first?.column == 0)
        // The second character's *last* column — a rectangle that stopped at
        // its first would clip half of it. A live accessibility probe showed
        // exactly that: three CJK characters outlined as five cells.
        #expect(asked.last?.column == 3)
        #expect(frame.width == 32)  // two wide characters: four columns
    }

    /// The column span of a character, which is what a rectangle needs and
    /// what its starting column alone cannot give.
    @Test func cellSpansReportHowManyColumnsACharacterOccupies() {
        var terminal = Self.terminal()
        terminal.feed(Array("a中b".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.cellSpan(forOffset: 0) == (row: 0, column: 0, columns: 1))
        #expect(snapshot.cellSpan(forOffset: 1) == (row: 0, column: 1, columns: 2))
        #expect(snapshot.cellSpan(forOffset: 2) == (row: 0, column: 3, columns: 1))
    }

    /// A combining sequence adds UTF-16 units without adding columns, so its
    /// span is one column however many units it carries.
    @Test func combiningSequencesSpanOneColumn() {
        var terminal = Self.terminal()
        terminal.feed(Array("e\u{301}x".utf8))
        let snapshot = Self.snapshot(terminal)
        #expect(snapshot.cellSpan(forOffset: 0).columns == 1)
        #expect(snapshot.cellSpan(forOffset: 1).columns == 1)
    }

    /// A zero-length range still outlines one cell — an empty rectangle is
    /// not something a cursor outline can be drawn from.
    @Test func aZeroLengthRangeStillOutlinesACell() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let grid = terminal.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(grid: grid, selection: nil)
        }
        view.accessibilityCellFrameProvider = { row, column in
            CGRect(x: CGFloat(column) * 8, y: CGFloat(row) * 17, width: 8, height: 17)
        }
        let frame = view.accessibilityFrame(for: NSRange(location: 2, length: 0))
        #expect(frame.width == 8)
        #expect(frame.height == 17)
    }
}
