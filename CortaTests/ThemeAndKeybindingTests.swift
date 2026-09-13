import AppKit
import Testing

@testable import Corta

/// M7.6 (config-file themes) and M7.7 (rebindable shortcuts) — both are new
/// key families in the config file, so both are tested through the same
/// parse-and-serialise round trip the rest of `Configuration` is.
@Suite struct ThemeAndKeybindingTests {
    // MARK: - Themes

    @Test("a theme defined in the config file is available by name")
    func customThemeIsParsed() {
        let (parsed, unknown) = Configuration.parse(
            """
            theme = midnight
            theme.midnight.name = Midnight
            theme.midnight.dark.background = #101018
            theme.midnight.dark.foreground = #e0e0f0
            """)
        #expect(unknown.isEmpty)
        #expect(parsed.customThemes.count == 1)
        let theme = try! #require(Theme.named("midnight", in: parsed))
        #expect(theme.displayName == "Midnight")
        #expect(theme.dark.background == Theme.color("#101018"))
        #expect(theme.dark.foreground == Theme.color("#e0e0f0"))
    }

    /// Anything unspecified inherits, so a two-line theme is a legal theme —
    /// requiring all nineteen colours would mean nobody ever writes one.
    @Test("unspecified colours inherit")
    func customThemeInherits() {
        let (parsed, _) = Configuration.parse(
            """
            theme.tint.inherit = solarized
            theme.tint.dark.cursor = #ff0000
            """)
        let theme = try! #require(Theme.named("tint", in: parsed))
        #expect(theme.dark.cursor == Theme.color("#ff0000"))
        #expect(theme.dark.background == Theme.solarized.dark.background)
        #expect(theme.light.ansi == Theme.solarized.light.ansi)
    }

    @Test("a single ANSI slot can be overridden")
    func customThemeOverridesOneANSISlot() {
        let (parsed, _) = Configuration.parse("theme.x.dark.ansi1 = #123456")
        let theme = try! #require(Theme.named("x", in: parsed))
        #expect(theme.dark.ansi[1] == Theme.color("#123456"))
        #expect(theme.dark.ansi[2] == Theme.corta.dark.ansi[2])
    }

    @Test("a custom theme survives a write and re-read")
    func customThemeRoundTrips() {
        let (parsed, _) = Configuration.parse(
            """
            theme = midnight
            theme.midnight.name = Midnight
            theme.midnight.dark.background = #101018
            """)
        let (reparsed, _) = Configuration.parse(parsed.serialized())
        #expect(reparsed.theme == "midnight")
        let theme = try! #require(Theme.named("midnight", in: reparsed))
        #expect(theme.displayName == "Midnight")
        #expect(theme.dark.background == Theme.color("#101018"))
        #expect(theme.dark.ansi == Theme.corta.dark.ansi)
    }

    /// A half-typed theme must still render — a config file is hand-edited,
    /// and a bad colour must not black out the terminal.
    @Test("a malformed colour is preserved, not applied")
    func malformedColourIsKeptAsUnknown() {
        let (parsed, unknown) = Configuration.parse("theme.x.dark.background = mauve")
        #expect(unknown.count == 1)
        let theme = try! #require(Theme.named("x", in: parsed))
        #expect(theme.dark.background == Theme.corta.dark.background)
    }

    @Test("both hex notations parse, and round-trip")
    func colourNotations() {
        #expect(Theme.color("#f00") == Theme.color("#ff0000"))
        #expect(Theme.color("ff0000") == Theme.color("#ff0000"))
        #expect(Theme.color("#12345") == nil)
        #expect(Theme.hex(Theme.color("#1a2b3c")!) == "#1a2b3c")
    }

    // MARK: - Shortcuts

    @Test("a shortcut parses and writes back as it was typed")
    func shortcutRoundTrips() {
        let shortcut = try! #require(Shortcut.parse("cmd+shift+d"))
        #expect(shortcut.key == "d")
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.text == "shift+cmd+d")
        #expect(Shortcut.parse(shortcut.text) == shortcut)
    }

    @Test("named keys parse")
    func namedKeys() {
        let up = try! #require(Shortcut.parse("ctrl+alt+up"))
        #expect(up.modifiers == [.control, .option])
        #expect(up.key == String(UnicodeScalar(NSUpArrowFunctionKey)!))
        #expect(up.text == "ctrl+alt+up")
    }

    @Test("nonsense does not parse")
    func rejectsNonsense() {
        #expect(Shortcut.parse("") == nil)
        #expect(Shortcut.parse("hyper+d") == nil)
        #expect(Shortcut.parse("cmd+notakey") == nil)
    }

    /// AppKit takes an uppercase key equivalent to *mean* shift; setting both
    /// makes a menu item render "⇧⇧".
    @Test("a shifted letter becomes an uppercase key equivalent")
    func menuFormFoldsShiftIntoTheLetter() {
        let shortcut = try! #require(Shortcut.parse("cmd+shift+d"))
        #expect(shortcut.menuKeyEquivalent == "D")
        #expect(shortcut.menuModifierMask == [.command])
    }

    @Test("a binding from the config file overrides the default")
    func bindingOverridesDefault() {
        let (parsed, unknown) = Configuration.parse("bind.split-right = ctrl+s")
        #expect(unknown.isEmpty)
        #expect(parsed.keybindings[.splitRight] == Shortcut.parse("ctrl+s"))
        // Untouched commands keep their defaults, so a changed default still
        // reaches a user who never overrode it.
        #expect(parsed.keybindings[.newTab] == TerminalCommand.newTab.defaultShortcut)
    }

    /// Unbinding has to stick: a user who took ⌘W away because a TUI wants it
    /// must not have it handed back.
    @Test("an empty binding removes the shortcut")
    func emptyBindingUnbinds() {
        let (parsed, _) = Configuration.parse("bind.close = ")
        #expect(parsed.keybindings[.close] == nil)
        let (reparsed, _) = Configuration.parse(parsed.serialized())
        #expect(reparsed.keybindings[.close] == nil)
    }

    @Test("only overridden bindings are written back")
    func onlyOverridesAreSerialized() {
        var configuration = Configuration()
        configuration.keybindings[.find] = Shortcut.parse("cmd+e")
        let text = configuration.serialized()
        #expect(text.contains("bind.find = cmd+e"))
        #expect(!text.contains("bind.new-tab"))
    }

    // MARK: - Matching a key event (U08)

    private static func event(
        _ characters: String, ignoring: String? = nil,
        modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false,
            keyCode: keyCode)!
    }

    /// `matches` is what stops a rebound command leaving its old key behind:
    /// the modifiers must be exactly the shortcut's, not merely include them.
    @Test("a shortcut matches its own keystroke and nothing else")
    func shortcutMatchesExactly() {
        let commandV = try! #require(Shortcut.parse("cmd+v"))
        #expect(commandV.matches(Self.event("v", modifiers: .command)))
        #expect(!commandV.matches(Self.event("v")))
        // The bug: a `contains(.command)` test called ⌘⇧V and ⌥⌘V pastes too.
        #expect(!commandV.matches(Self.event("V", ignoring: "V", modifiers: [.command, .shift])))
        #expect(!commandV.matches(Self.event("√", ignoring: "v", modifiers: [.command, .option])))
    }

    /// AppKit hands a shifted letter over uppercased, and modifiers AppKit
    /// sets for its own reasons (`.function`, `.numericPad`, Caps Lock) are
    /// not part of the notation and must not defeat a match.
    @Test("a shifted letter and AppKit's incidental flags still match")
    func shortcutMatchingNormalises() {
        let shifted = try! #require(Shortcut.parse("cmd+shift+d"))
        #expect(shifted.matches(Self.event("D", ignoring: "D", modifiers: [.command, .shift])))
        let up = try! #require(Shortcut.parse("cmd+up"))
        let scalar = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        #expect(
            up.matches(
                Self.event(
                    scalar, modifiers: [.command, .function, .numericPad], keyCode: 126)))
        #expect(
            up.matches(
                Self.event(
                    scalar, modifiers: [.command, .capsLock, .function], keyCode: 126)))
    }

    @Test("every command has a distinct config key and a title")
    func commandTableIsWellFormed() {
        let keys = Set(TerminalCommand.allCases.map(\.configurationKey))
        #expect(keys.count == TerminalCommand.allCases.count)
        for command in TerminalCommand.allCases {
            #expect(!command.title.isEmpty)
        }
    }

    // MARK: - The palette's filter (M7.12)

    @Test("an abbreviation finds the command it abbreviates")
    func paletteFuzzyMatching() {
        let split = try! #require(
            CommandPaletteModel.score("split pane right", query: "spr"))
        let unrelated = CommandPaletteModel.score("copy", query: "spr")
        #expect(unrelated == nil)
        #expect(split > 0)
    }

    @Test("a shorter title wins a tie")
    func paletteRanksShorterTitlesFirst() {
        let short = try! #require(CommandPaletteModel.score("copy", query: "cop"))
        let long = try! #require(CommandPaletteModel.score("copy on select", query: "cop"))
        #expect(short > long)
    }

    // MARK: - New scalar settings

    /// U05 — `option-as-meta` was serialised but had no parse case, so a
    /// user who typed it into the file got an "unknown key" and the setting
    /// never applied; the settings page had no switch for it either. The
    /// round trip is what catches a write-only key.
    @Test("option-as-meta round-trips through the config file")
    func optionAsMetaRoundTrips() {
        let (parsed, unknown) = Configuration.parse("option-as-meta = true")
        #expect(unknown.isEmpty)
        #expect(parsed.optionAsMeta)
        #expect(parsed.serialized().contains("option-as-meta = true"))
        let (reparsed, reunknown) = Configuration.parse(parsed.serialized())
        #expect(reunknown.isEmpty)
        #expect(reparsed.optionAsMeta)
        // The default stays off: ⌥ is text input on macOS.
        #expect(!Configuration().optionAsMeta)
    }

    @Test("the new terminal and window settings round-trip")
    func newSettingsRoundTrip() {
        var configuration = Configuration()
        configuration.optionAsMeta = true
        // The non-default: copy-on-select ships on (M7.10).
        configuration.copyOnSelect = false
        configuration.linkActivation = .click
        configuration.allowClipboardWrite = true
        configuration.restoreWindows = false
        configuration.confirmClose = false
        let (reparsed, _) = Configuration.parse(configuration.serialized())
        #expect(reparsed == configuration)
    }

    /// The bug this replaced: Settings wrote `bell` to the config file while
    /// the bell itself read a `UserDefaults` key, so the setting did nothing.
    @Test("the bell mode comes from the config file")
    func bellRoundTrips() {
        let (parsed, _) = Configuration.parse("bell = audible")
        #expect(parsed.bell == .audible)
        #expect(parsed.serialized().contains("bell = audible"))
    }
}
