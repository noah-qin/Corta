import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U11 — Clear Screen, Clear History and Reset Terminal.
///
/// The point of three commands is that each one discards a different thing,
/// so the table in `CONFIGURATION.md` §5 is the specification and these are
/// it, asserted. A command that quietly did what one of the others does would
/// be worse than not having it — the whole reason they are separate is that
/// "clear" means three different things across terminals.
struct TerminalStateCommandTests {
    private static func filled() -> Terminal {
        var terminal = Terminal(rows: 4, columns: 20, scrollbackLimit: 100)
        for line in 0..<10 { terminal.feed(Array("line\(line)\r\n".utf8)) }
        terminal.feed(Array("prompt".utf8))
        return terminal
    }

    @Test("clear screen erases the screen and keeps the history")
    func clearScreenKeepsHistory() {
        var terminal = Self.filled()
        let historyBefore = terminal.grid.scrollback.count
        #expect(historyBefore > 0)
        terminal.grid.clearScreen()
        for row in 0..<terminal.grid.rows {
            #expect(terminal.grid.rowText(row).trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(terminal.grid.scrollback.count == historyBefore)
        // Cursor home, not left wherever the output had reached — `ED 2`
        // alone leaves it mid-screen, which reads as a bug.
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 0))
    }

    @Test("clear history discards the scrollback and keeps the screen")
    func clearHistoryKeepsScreen() {
        var terminal = Self.filled()
        let screen = (0..<terminal.grid.rows).map { terminal.grid.rowText($0) }
        let cursor = terminal.grid.cursor
        terminal.grid.clearScrollback()
        #expect(terminal.grid.scrollback.count == 0)
        #expect((0..<terminal.grid.rows).map { terminal.grid.rowText($0) } == screen)
        #expect(terminal.grid.cursor == cursor)
    }

    @Test("reset discards both and puts the modes back")
    func resetClearsEverything() {
        var terminal = Self.filled()
        terminal.feed(Array("\u{1B}[?1h\u{1B}=\u{1B}[?2004h".utf8))
        #expect(terminal.applicationCursorKeysEnabled)
        #expect(terminal.applicationKeypadEnabled)
        terminal.reset()
        #expect(terminal.grid.scrollback.count == 0)
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 0))
        for row in 0..<terminal.grid.rows {
            #expect(terminal.grid.rowText(row).trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(!terminal.applicationCursorKeysEnabled)
        #expect(!terminal.applicationKeypadEnabled)
        #expect(!terminal.isBracketedPasteEnabled)
    }

    /// The three are distinguishable: no two produce the same result from the
    /// same starting terminal. If they did, one of them would be a lie.
    @Test("the three commands differ from each other")
    func theThreeAreDistinct() {
        var cleared = Self.filled()
        cleared.grid.clearScreen()
        var history = Self.filled()
        history.grid.clearScrollback()
        var reset = Self.filled()
        reset.reset()

        #expect(cleared.grid.scrollback.count != history.grid.scrollback.count)
        #expect(cleared.grid.rowText(0) != history.grid.rowText(0))
        #expect(reset.grid.scrollback.count == history.grid.scrollback.count)
        #expect(reset.grid.rowText(0) == cleared.grid.rowText(0))
    }
}

/// The commands' app-level wiring: three entries in the one table the menus,
/// the palette and the config file all read.
@MainActor
struct TerminalStateCommandWiringTests {
    @Test func allThreeAreRealCommands() {
        for command in [TerminalCommand.clearScreen, .clearHistory, .resetTerminal] {
            #expect(!command.title.isEmpty)
            #expect(command.category == .terminal)
            #expect(command.configurationKey.hasPrefix("bind."))
        }
    }

    /// ⌘K is what every Mac terminal puts on "clear what is on screen"; the
    /// other two ship unbound because both throw history away.
    @Test func onlyClearScreenCarriesADefaultKey() {
        #expect(TerminalCommand.clearScreen.defaultShortcut == Shortcut.parse("cmd+k"))
        #expect(TerminalCommand.clearHistory.defaultShortcut == nil)
        #expect(TerminalCommand.resetTerminal.defaultShortcut == nil)
    }

    @Test func allThreeAreInTheShellMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        for command in [TerminalCommand.clearScreen, .clearHistory, .resetTerminal] {
            #expect(
                shell.items.contains { $0.action == command.action },
                "\(command.rawValue) is not in the Shell menu")
        }
    }
}
