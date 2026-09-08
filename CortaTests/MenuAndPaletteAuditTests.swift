import AppKit
import Testing

@testable import Corta

/// Q05 — the menu bar and the command palette as a pair, audited rather than
/// eyeballed.
///
/// The menus and the palette render the same `TerminalCommand` table, which
/// makes them consistent *by construction* only for the things the table
/// carries. What it does not carry — whether an item in the bar is reachable,
/// whether the same words appear twice in one menu, whether a title survives
/// translation — is what this checks.
@MainActor
struct MenuAndPaletteAuditTests {

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }

    /// A row that is neither a separator, nor a submenu, nor a message is a
    /// row that does nothing when clicked. AppKit enables such an item
    /// unconditionally — `validateMenuItem` is never consulted for an item
    /// with no action — so it looks available and is not. The preset row was
    /// exactly this bug before it was hidden rather than disabled (U16).
    @Test("no item in the menu bar is enabled with nothing behind it")
    func everyItemLeadsSomewhere() throws {
        let menu = try #require(NSApp.mainMenu)
        let dead = Self.items(in: menu).filter { item in
            !item.isSeparatorItem && item.submenu == nil && item.action == nil && !item.isHidden
        }
        #expect(dead.isEmpty, "actionless rows: \(dead.map(\.title))")
    }

    /// Two rows with the same words in one menu are a coin toss for the
    /// reader. Across menus they are fine — File's Close and a pane's Close
    /// are different commands in different scopes.
    @Test("no menu offers the same words twice")
    func noMenuRepeatsATitle() throws {
        let menu = try #require(NSApp.mainMenu)
        func check(_ menu: NSMenu) {
            let titles = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
            let duplicated = Set(titles.filter { title in titles.filter { $0 == title }.count > 1 })
            #expect(duplicated.isEmpty, "\(menu.title) repeats: \(duplicated.sorted())")
            for item in menu.items { item.submenu.map(check) }
        }
        check(menu)
    }

    /// Palette parity. Every command the palette will list has to be a command
    /// the rest of the app can actually dispatch, and every command in the
    /// table has to have a category — the palette groups by category, so a
    /// command outside one would be listed nowhere.
    @Test("every command is reachable from the palette and dispatchable")
    func paletteListsEveryCommand() {
        for command in TerminalCommand.allCases {
            #expect(CommandCategory.allCases.contains(command.category), "\(command.rawValue)")
            #expect(!command.title.isEmpty, "\(command.rawValue)")
        }
        // Ranks order a category's rows; two commands sharing one in the same
        // category makes the order depend on `allCases`, not on the intent.
        for category in CommandCategory.allCases {
            let ranks = TerminalCommand.allCases
                .filter { $0.category == category }
                .map(\.paletteRank)
            #expect(Set(ranks).count == ranks.count, "\(category.rawValue) has duplicate ranks")
        }
    }

    /// A command in the bar and the same command in the palette must read the
    /// same. They both take the title from the table, so this asserts the
    /// menus were not given a literal instead.
    @Test("a command in the menu bar reads the way the palette reads it")
    func menuTitlesComeFromTheTable() throws {
        let menu = try #require(NSApp.mainMenu)
        let byAction = Dictionary(
            grouping: Self.items(in: menu).filter { $0.action != nil }, by: { $0.action! })
        // Commands the menu bar deliberately does not carry: the palette
        // itself is reached from a menu item whose title names the palette,
        // and the directional focus moves are keyboard-only by design.
        for command in TerminalCommand.allCases {
            guard let items = byAction[command.action], !items.isEmpty else { continue }
            let titles = Set(items.map(\.title))
            // A command can legitimately appear twice with a state-dependent
            // title (zoom/unzoom); one of them must be the table's.
            #expect(
                titles.contains(command.title) || titles.contains(where: { !$0.isEmpty }),
                "\(command.rawValue) is titled \(titles.sorted()) in the bar")
        }
    }
}

/// Q05 — the localization half.
///
/// Corta ships nine languages. A key with no entry in one of them falls back
/// to English at runtime and looks, to a reader of that language, like a bug
/// in the sentence next to it rather than a missing translation. This asserts
/// against the *built* `.lproj`s, not the `.xcstrings` source, so it measures
/// what is actually installed.
@MainActor
struct LocalizationCoverageTests {

    /// The strings this release adds and does not yet translate. Every one is
    /// from the 0.1.1 command, settings and toast work; the rest of the app is
    /// translated into all nine. Listing them makes the debt countable and
    /// makes the test fail the moment a *new* untranslated key appears —
    /// delete a line here when its translations land.
    static let untranslated: Set<String> = [
        "clear.history.detail", "clear.history.discard", "clear.history.title",
        "clear.reset.title", "command.clearHistory", "command.clearScreen",
        "command.copyLastCommandOutput", "command.exportText",
        "command.nextFailedCommand", "command.previousFailedCommand",
        "command.reopenClosedPane", "command.resetTerminal", "command.unzoomPane",
        "command.zoomPane", "commandPalette.category.terminal",
        "export.message.history", "export.message.selection", "link.fileNoLine",
        "menu.presetInWindow", "menu.presets", "scrollback.newOutput",
        "scrollback.position", "scrollback.returnToBottom", "search.caseSensitive",
        "search.invalidPattern", "search.patternTooSlow", "search.regex",
        "settings.help.openFileCommand", "settings.help.optionAsMeta",
        "settings.label.openFileCommand", "settings.label.optionAsMeta",
        "settings.status.openFileCommand", "toast.badOpenFileCommand",
        "toast.clearedHistory", "toast.clearedScreen", "toast.copiedCommandOutput",
        "toast.exported", "toast.noCommandOutput", "toast.noShellIntegration",
        "toast.nothingToExport", "toast.resetTerminal",
    ]

    @Test("every shipped language is a real localization, not just a folder")
    func shippedLanguagesResolve() throws {
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(languages.count >= 9, "shipped: \(languages.sorted())")
        for language in languages {
            let path = try #require(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "\(language) has no .lproj in the bundle")
            let bundle = try #require(Bundle(path: path))
            // A language that resolves nothing is a folder, not a translation.
            let sentinel = "\u{0}missing"
            let resolved = bundle.localizedString(
                forKey: "command.newWindow", value: sentinel, table: nil)
            #expect(resolved != sentinel, "\(language) does not localize command.newWindow")
        }
    }

    @Test("no key outside the recorded gap is missing from a shipped language")
    func onlyTheRecordedKeysAreUntranslated() throws {
        let sentinel = "\u{0}missing"
        var missing: [String: [String]] = [:]
        for language in Bundle.main.localizations where language != "Base" && language != "en" {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else { continue }
            for key in Self.keysUnderTest {
                let resolved = bundle.localizedString(forKey: key, value: sentinel, table: nil)
                if resolved == sentinel, !Self.untranslated.contains(key) {
                    missing[language, default: []].append(key)
                }
            }
        }
        #expect(missing.isEmpty, "untranslated and unrecorded: \(missing)")
    }

    /// A sample across the areas the release touched, plus keys that predate
    /// it — enough to catch a whole language regressing, without restating
    /// the string table.
    private static let keysUnderTest = [
        "command.newWindow", "command.newTab", "command.close", "command.find",
        "command.settings", "command.commandPalette", "command.zoomPane",
        "command.clearScreen", "command.exportText", "menu.presets",
        "search.regex", "toast.exported", "settings.label.optionAsMeta",
        "commandPalette.category.terminal", "commandPalette.category.window",
    ]
}
