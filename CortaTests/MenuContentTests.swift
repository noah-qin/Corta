import AppKit
import Testing

@testable import Corta

/// UI05 / M02 and M04 — what the menus call things, and whether the promises
/// they make are kept.
///
/// `MenuShortcutTests` pins *which keys* the menu bar claims; this pins the
/// words: File's New is a new window under the same name the palette and the
/// shortcuts sheet use, and Corta Help leads somewhere real instead of the
/// storyboard template's `showHelp:` against a help book Corta never shipped.
@MainActor
struct MenuContentTests {
    /// Every item in the menu bar, depth-first.
    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map { items(in: $0) } ?? [])
        }
    }

    @Test("File's New names the window it opens, under the palette's name for the same command")
    func fileNewIsNewWindow() throws {
        let menu = try #require(NSApp.mainMenu)
        let new = try #require(
            Self.items(in: menu).first {
                $0.action == #selector(AppDelegate.newDocument(_:))
            },
            "the File menu must carry the new-window command")
        // One name everywhere: the menu item, the palette and the shortcuts
        // sheet all read `TerminalCommand.newWindow.title`. Compared against
        // the command's title rather than a literal, so the assertion holds
        // in every localization at once.
        #expect(new.title == TerminalCommand.newWindow.title)
        #expect(new.title == L10n.text("command.newWindow"))
    }

    @Test("Corta Help opens the documentation, not an empty help book")
    func cortaHelpHasARealDestination() throws {
        let menu = try #require(NSApp.mainMenu)
        let items = Self.items(in: menu)
        // The template action searches Help Viewer for a help book that does
        // not exist; no item in the bar may still send it.
        #expect(items.allSatisfy { $0.action != #selector(NSApplication.showHelp(_:)) })
        let cortaHelp = try #require(
            items.first {
                $0.action == #selector(AppDelegate.showHelpDocumentation(_:))
            },
            "the Help menu must keep a Corta Help item")
        #expect(cortaHelp.target === NSApp.delegate)
        #expect(AppDelegate.helpURL.scheme == "https")
        #expect(AppDelegate.helpURL.host == "github.com")
    }
}
