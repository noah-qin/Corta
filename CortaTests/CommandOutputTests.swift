import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U14 — the two things OSC 133 marks make possible that Corta was not yet
/// doing: taking the last command's output without selecting it by hand, and
/// navigating to the commands that *failed* rather than to every command.
struct CommandOutputTests {
    /// A terminal with real `OSC 133` marks, driven the way a shell with
    /// integration configured drives them: `A` at each prompt, `D;status`
    /// when the command finishes.
    private static func session(commands: [(command: String, output: [String], status: Int)])
        -> Terminal
    {
        var terminal = Terminal(rows: 24, columns: 40, scrollbackLimit: 500)
        for entry in commands {
            terminal.feed(Array("\u{1B}]133;A\u{7}$ \(entry.command)\r\n".utf8))
            for line in entry.output { terminal.feed(Array("\(line)\r\n".utf8)) }
            terminal.feed(Array("\u{1B}]133;D;\(entry.status)\u{7}".utf8))
        }
        // The prompt now waiting for input, as a real shell would print it.
        terminal.feed(Array("\u{1B}]133;A\u{7}$ ".utf8))
        return terminal
    }

    // MARK: - Marks

    @Test("prompt rows and failed prompt rows are both found")
    func marksAreRecorded() {
        let terminal = Self.session(commands: [
            ("true", ["ok"], 0),
            ("false", ["boom"], 1),
        ])
        let grid = terminal.grid
        #expect(grid.promptRows.count == 3)  // two commands plus the live prompt
        #expect(grid.failedPromptRows.count == 1)
        #expect(grid.failedPromptRows.first == grid.promptRows[1])
    }

    @Test("a session where nothing failed has no failed prompts")
    func noFailuresMeansNoRows() {
        let terminal = Self.session(commands: [("true", ["ok"], 0)])
        #expect(terminal.grid.failedPromptRows.isEmpty)
    }

    // MARK: - The last command's output

    @Test("the last command's output is the rows between the two prompts")
    func lastOutputIsBetweenPrompts() throws {
        let terminal = Self.session(commands: [
            ("echo one", ["one"], 0),
            ("echo two", ["two", "and more"], 0),
        ])
        let text = try #require(ViewController.lastCommandOutput(in: terminal.grid))
        #expect(text.contains("two"))
        #expect(text.contains("and more"))
        // Not the command line itself, and not the earlier command's output.
        #expect(!text.contains("echo two"))
        #expect(!text.contains("one"))
    }

    /// The output can be longer than the screen — that is the case the
    /// feature exists for, because selecting it by hand means dragging into
    /// the scrollback.
    @Test("output that has scrolled into the history is still taken whole")
    func outputSpanningTheScrollback() throws {
        let lines = (0..<80).map { "line\($0)" }
        let terminal = Self.session(commands: [
            ("short", ["ignored"], 0),
            ("long", lines, 0),
        ])
        let text = try #require(ViewController.lastCommandOutput(in: terminal.grid))
        #expect(text.contains("line0"))
        #expect(text.contains("line79"))
        #expect(!text.contains("ignored"))
    }

    /// No marks at all is a shell with no integration configured; marks but
    /// no completed command is a fresh prompt. Neither is an error and
    /// neither invents an answer.
    @Test("no completed command means no output, not a guess")
    func nothingToCopy() {
        var bare = Terminal(rows: 24, columns: 40, scrollbackLimit: 100)
        bare.feed(Array("$ ls\r\nfile\r\n".utf8))
        #expect(bare.grid.promptRows.isEmpty)
        #expect(ViewController.lastCommandOutput(in: bare.grid) == nil)

        var fresh = Terminal(rows: 24, columns: 40, scrollbackLimit: 100)
        fresh.feed(Array("\u{1B}]133;A\u{7}$ ".utf8))
        #expect(ViewController.lastCommandOutput(in: fresh.grid) == nil)
    }

    /// A command that printed nothing has an empty range, not a range over
    /// the next prompt.
    @Test("a command that printed nothing yields no output")
    func silentCommand() {
        let terminal = Self.session(commands: [("true", [], 0)])
        #expect(ViewController.lastCommandOutput(in: terminal.grid) == nil)
    }
}

/// The commands' place in the one table the menus, palette and config file
/// all read.
@MainActor
struct CommandOutputWiringTests {
    @Test func theThreeCommandsExist() {
        for command in [
            TerminalCommand.previousFailedCommand, .nextFailedCommand, .copyLastCommandOutput,
        ] {
            #expect(!command.title.isEmpty)
            #expect(command.category == .view)
        }
    }

    /// ⇧⌘↑/↓ narrow the ⌘↑/↓ gesture to the commands that failed; copying
    /// the output ships unbound because it overwrites the clipboard and there
    /// is no key that reads as "do that".
    @Test func failedCommandJumpsSitNextToTheOrdinaryOnes() {
        #expect(
            TerminalCommand.previousFailedCommand.defaultShortcut
                == Shortcut.parse("shift+cmd+up"))
        #expect(
            TerminalCommand.nextFailedCommand.defaultShortcut == Shortcut.parse("shift+cmd+down"))
        #expect(TerminalCommand.copyLastCommandOutput.defaultShortcut == nil)
    }

    @Test func allThreeAreInTheShellMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        for command in [
            TerminalCommand.previousFailedCommand, .nextFailedCommand, .copyLastCommandOutput,
        ] {
            #expect(shell.items.contains { $0.action == command.action })
        }
    }
}
