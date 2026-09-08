import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U15 — putting a closed pane back, and writing what is in a pane to a file.
@MainActor
@Suite(.serialized)
struct ReopenClosedPaneTests {
    private func makeSplit(panes count: Int) -> SplitViewController {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        for _ in 1..<count { split.splitFocusedPane(orientation: .columns) }
        split.view.layoutSubtreeIfNeeded()
        return split
    }

    @Test func aClosedPaneComesBackInItsOwnPlace() throws {
        let split = makeSplit(panes: 2)
        defer { split.teardown() }
        let closed = try #require(split.focusedPane)
        #expect(!split.canReopenClosedPane)

        split.closePane(closed)
        #expect(split.panes.count == 1)
        #expect(split.canReopenClosedPane)

        split.reopenClosedPane(nil)
        #expect(split.panes.count == 2)
        // A fresh child, not the old one — the pane is back, the process is
        // not, and the command is named "Reopen", not "Undo Close".
        #expect(split.panes.allSatisfy { $0.session != nil })
        #expect(!split.panes.contains { $0 === closed })
        // One reopen empties the record: there is nothing else to bring back.
        #expect(!split.canReopenClosedPane)
    }

    /// The record describes a position relative to a sibling. If the sibling
    /// closed too, that position no longer exists, and opening a pane
    /// somewhere arbitrary would not be a restore.
    @Test func aVanishedSiblingMeansNothingToReopen() throws {
        let split = makeSplit(panes: 2)
        defer { split.teardown() }
        let first = try #require(split.panes.first)
        let second = try #require(split.panes.last)
        split.closePane(second)
        #expect(split.canReopenClosedPane)
        // Closing the sibling as well leaves the record unusable.
        split.closePane(first)
        #expect(!split.canReopenClosedPane)
    }

    /// The last pane in a window is the window; closing it is the window's
    /// business (`SessionRestore`), not this record's.
    @Test func closingTheLastPaneRecordsNothing() throws {
        let split = makeSplit(panes: 1)
        defer { split.teardown() }
        let only = try #require(split.focusedPane)
        split.closePane(only)
        #expect(!split.canReopenClosedPane)
    }

    @Test func theMenuItemIsDisabledWithNothingToReopen() throws {
        let split = makeSplit(panes: 2)
        defer { split.teardown() }
        let item = NSMenuItem(
            title: "", action: #selector(SplitViewController.reopenClosedPane(_:)),
            keyEquivalent: "")
        #expect(!split.validateMenuItem(item))
        split.closePane(try #require(split.focusedPane))
        #expect(split.validateMenuItem(item))
    }
}

/// The export's rule: the selection if there is one, the whole document if
/// there is not — and the same joining the clipboard does.
struct ExportTextTests {
    private static func terminal() -> Terminal {
        var terminal = Terminal(rows: 4, columns: 12, scrollbackLimit: 100)
        for line in 0..<8 { terminal.feed(Array("line\(line)\r\n".utf8)) }
        return terminal
    }

    @Test("with no selection the whole document is exported")
    func wholeDocument() {
        let grid = Self.terminal().grid
        let text = ViewController.exportableText(grid: grid, selection: nil)
        // Both ends: the scrollback's oldest line and the live screen's.
        #expect(text.contains("line0"))
        #expect(text.contains("line7"))
    }

    @Test("with a selection only the selection is exported")
    func selectionOnly() {
        let grid = Self.terminal().grid
        let selection = SelectionRange(
            anchor: SelectionPoint(row: -2, column: 0),
            head: SelectionPoint(row: -2, column: grid.columns - 1))
        let text = ViewController.exportableText(grid: grid, selection: selection)
        #expect(text.contains("line"))
        #expect(!text.contains("line0"))
        #expect(text.split(separator: "\n").count == 1)
    }

    /// A soft-wrapped line is one line in the file, exactly as it is one line
    /// on the clipboard — the `wrapped` flag is what both read.
    @Test("a soft-wrapped line exports as one line")
    func wrappedLinesJoin() {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("abcdefghijklmno".utf8))  // wraps at 10 columns
        let text = ViewController.exportableText(grid: terminal.grid, selection: nil)
        #expect(text.contains("abcdefghijklmno"))
    }

    /// A folder of exports has to stay readable, so the name says what it is
    /// and when it was taken.
    @Test("the suggested filename says what and when")
    func filename() {
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let history = ViewController.exportFilename(hasSelection: false, date: date)
        let selection = ViewController.exportFilename(hasSelection: true, date: date)
        #expect(history.hasPrefix("Corta History "))
        #expect(selection.hasPrefix("Corta Selection "))
        #expect(history.hasSuffix(".txt"))
        #expect(history != selection)
    }
}
