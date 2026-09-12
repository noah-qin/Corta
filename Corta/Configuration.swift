import AppKit
import CortaTerminal
import Foundation

/// M6.1 — everything the settings page can change, and the text format the
/// config file stores it in.
///
/// One file is the source of truth. The settings page edits that file and
/// reads it back; there is no second store to drift out of sync, and a
/// hand-edit in `$EDITOR` is as valid an input as a click. That constraint
/// is why this type owns both the values and their serialisation.
///
/// The format is `key = value`, one per line, `#` to end of line for
/// comments — chosen because it needs no third-party parser and stays
/// readable when hand-edited. A `#` that opens a *value* is not a comment:
/// that is how a colour is written. An unknown key is preserved on write rather
/// than dropped: a config written by a newer Corta must survive a round trip
/// through an older one.
///
/// Two families of key are structured rather than scalar, and both use a
/// dotted prefix so the flat format does not need nesting: `theme.<name>.…`
/// defines a colour theme (M7.6), and `bind.<command>` rebinds a keyboard
/// shortcut (M7.7).
nonisolated struct Configuration: Equatable, Sendable {
    /// Which of a theme's two variants is live (M6.13).
    enum Appearance: String, CaseIterable, Sendable {
        /// Follow macOS, switching live when the system does.
        case auto
        case light
        case dark
    }

    /// What it takes to open a link (M7.9).
    enum LinkActivation: String, CaseIterable, Sendable {
        /// ⌘-click, the original behaviour: the modifier is the confirmation.
        case command
        /// A plain click on a link opens it, and hovering one underlines it
        /// so the target is visible before the click. Selection still wins
        /// the moment the mouse moves, so dragging across a URL selects it.
        case click
    }

    var fontFamily: String = Configuration.systemFontFamily
    var fontSize: Double = 12
    var theme: String = Theme.corta.name
    var appearance: Appearance = .auto
    var scrollbackLines: Int = 10_000
    /// B08 — the bound on `CommandRecordStore`'s per-session history,
    /// distinct from `scrollbackLines`: this caps structured command
    /// records (for jumping, copying and the command-history search), not
    /// visible text.
    var commandHistoryLimit: Int = CommandRecordStore.defaultCapacity
    /// The grid a new window opens with (M7.14). In *cells*, not points: the
    /// window's pixel size is this grid times the font's cell metrics plus
    /// the pane insets, which is what keeps `columns × rows` meaning the same
    /// thing after a font or size change.
    var columns: Int = 120
    var rows: Int = 30
    var bell: BellMode = .visual
    /// Whether a command that ran longer than `notificationThreshold` posts
    /// a notification when it finishes (M6.3).
    var notifyOnLongTask: Bool = false
    /// Seconds a command must run before finishing it is worth a
    /// notification. Below this a notification is noise — the user was
    /// watching.
    var notificationThreshold: Double = 30
    /// M7.10 — a finished selection goes straight to the pasteboard, the way
    /// X11 and every terminal that grew up beside it behave.
    ///
    /// On by default. It was off because copying silently replaces the
    /// clipboard and that surprises anyone who did not ask for it — but the
    /// copy is no longer silent: a confirmation appears in the corner of the
    /// pane (`TerminalView.showToast`), which is exactly the objection
    /// answered. What is left is the behaviour most people selecting text in
    /// a terminal already expect.
    var copyOnSelect: Bool = true
    /// M7.9 — see `LinkActivation`.
    var linkActivation: LinkActivation = .command
    /// U05 — ⌥ as Meta: an Option-modified text key sends ESC plus the base
    /// character, the way a PC's Alt key reaches readline (`\eb` for
    /// Option+B, and so on). Off by default: on a Mac, Option is how the
    /// layout's alternate characters (é, ø, π) and dead keys are typed, and
    /// taking that away is a choice only the user can make.
    var optionAsMeta: Bool = false

    /// U12 — whether scrollback search distinguishes case. Off by default:
    /// a person searching a log for `error` wants `Error` and `ERROR` too,
    /// and the toggle in the search bar writes here so the choice survives
    /// closing the bar and restarting the app.
    var searchCaseSensitive: Bool = false

    /// U16 — whether the search field is read as a regular expression. Like
    /// `search-case-sensitive`, the bar's own toggle writes it, so the mode
    /// survives closing the bar.
    var searchRegex: Bool = false

    /// U17 — the command that opens a `path:line` reference, with `{file}`,
    /// `{line}` and `{column}` substituted. Empty means the system default
    /// application, which cannot be told a line number.
    var openFileCommand: String = ""

    /// Whether an `open-file-command` template could actually be run: empty
    /// (meaning the system default application), or a command whose first
    /// word is an absolute path. A template that names no `{file}` is
    /// allowed — an editor that takes the path last is a real shape — but
    /// one that names an unknown placeholder is not, because the placeholder
    /// would be passed through as a literal argument.
    ///
    /// Split on *any* whitespace, which is what `openFileArguments` does when
    /// it launches the thing. Splitting on the space alone let a tab or a
    /// newline inside the template pass this check and then fail at
    /// `Process.run` — a value the file says is configured and the app will
    /// never execute, which is precisely what refusing it here is for.
    static func isUsableOpenFileCommand(_ template: String) -> Bool {
        // A line break inside the template is refused rather than tolerated.
        // `serialized()` interpolates this value straight into
        // `open-file-command = …`, and the config file is read a line at a
        // time, so storing one would write a second line the parser reads as
        // a stray key — a value that corrupts the file it is written to.
        // Trimming the ends is not enough: the settings field takes a paste.
        guard !template.contains(where: \.isNewline) else { return false }
        let parts = template.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = parts.first else { return true }
        guard executable.hasPrefix("/") else { return false }
        let known = ["{file}", "{line}", "{column}"]
        for part in parts {
            var rest = part
            while let open = rest.firstIndex(of: "{") {
                guard let close = rest[open...].firstIndex(of: "}") else { return false }
                guard known.contains(String(rest[open...close])) else { return false }
                rest = String(rest[rest.index(after: close)...])
            }
        }
        return true
    }
    /// M7.11 — whether OSC 52 may write the system pasteboard.
    ///
    /// Off by default, as `SECURITY.md` §2.6 requires: any output at all
    /// could put `rm -rf ~` or an attacker's wallet address on the clipboard
    /// for the user to paste later, and that is not a risk to take on
    /// somebody's behalf. Turning it on is one switch in Settings, which is
    /// what the feature is for — inside `tmux` or over `ssh` there is no
    /// other route to the local clipboard. The *read* half stays unavailable
    /// under every setting (`SECURITY.md` §6).
    var allowClipboardWrite: Bool = false
    /// B08 — whether Corta remembers visited directories (`OSC 7`) to rank
    /// for the directory switcher. On by default: unlike clipboard write,
    /// nothing here reaches outside the app, and the data is app-managed
    /// history, not a setting — `DirectoryHistory` persists it to its own
    /// file, not this one, the same split `ConfigurationStore` draws
    /// between preference and state. This key only gates whether it is
    /// kept at all; clearing what is already kept is a Settings action, not
    /// a config-file key.
    var directoryHistory: Bool = true
    /// M7.4 — reopen the windows, splits and working directories from the
    /// last run.
    var restoreWindows: Bool = true
    /// M7.5 — ask before closing a pane whose shell still has a child
    /// process running.
    var confirmClose: Bool = true
    /// Whether Sparkle checks for updates in the background, on the
    /// interval `SUScheduledCheckInterval` sets (`Sparkle-Info.plist`).
    /// Check for Updates… (`AppDelegate+Menus`, `UpdateController`) always
    /// works, on or off — this only gates the unattended check nobody
    /// asked for.
    var updateAutoCheck: Bool = true
    /// Offer to move Corta into /Applications on launch when it is not
    /// already there (`ApplicationsFolderMover`). Off after the user
    /// either moves it or says not to ask again.
    var suggestApplicationsFolder: Bool = true

    /// Themes defined in the config file itself (M7.6), in file order.
    var customThemes: [Theme] = []

    /// U16 — named shell/directory/environment presets, in the order the
    /// config file lists them, which is the order the menu offers them.
    var presets: [Preset] = []
    /// Keyboard shortcuts, defaults plus the file's overrides (M7.7).
    var keybindings = Keybindings()

    /// The sentinel meaning "whatever `NSFont.monospacedSystemFont` gives",
    /// which is the default and tracks the OS rather than pinning a face.
    static let systemFontFamily = "system"

    init() {}

    // MARK: - Parsing

    /// Parses a config file. Unparseable lines are skipped, not fatal: a
    /// typo in one setting must not cost the user every other setting, and
    /// the terminal has to start.
    ///
    /// Returns the parsed configuration and the keys it did not recognise,
    /// so `serialized(preserving:)` can write them back untouched. A
    /// recognised key whose value cannot be parsed at all (`font-size =
    /// banana`) is unrecognised too: the value falls back to the default and
    /// the line is preserved rather than rewritten.
    static func parse(_ text: String) -> (configuration: Configuration, unknown: [(String, String)]) {
        var configuration = Configuration()
        var unknown: [(String, String)] = []
        // Theme keys arrive one colour at a time and in any order, so they
        // accumulate into drafts and are resolved once the whole file is
        // read — a theme that inherits from another has to be able to name
        // one defined further down.
        var themeDrafts: [String: ThemeDraft] = [:]
        var themeOrder: [String] = []
        var presetDrafts: [String: Preset] = [:]
        var presetOrder: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A `#` opens a comment — except as the first character of a
            // *value*, where it is a colour (`background = #101018`). Splitting
            // the key from the value before stripping comments is what makes
            // both readings possible; stripping first ate every theme colour
            // in the file and left the key with an empty value.
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if let comment = value.dropFirst().firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }
            if key.hasPrefix("theme.") {
                if applyThemeKey(key, value: value, drafts: &themeDrafts, order: &themeOrder) {
                    continue
                }
                unknown.append((key, value))
            } else if key.hasPrefix("preset.") {
                if applyPresetKey(key, value: value, drafts: &presetDrafts, order: &presetOrder) {
                    continue
                }
                unknown.append((key, value))
            } else if key.hasPrefix("bind.") {
                if let command = TerminalCommand(rawValue: String(key.dropFirst("bind.".count))) {
                    // An empty value unbinds; a malformed one is left alone
                    // rather than silently reverting to the default.
                    configuration.keybindings[command] =
                        value.isEmpty ? nil : (Shortcut.parse(value) ?? command.defaultShortcut)
                    continue
                }
                unknown.append((key, value))
            } else if !configuration.apply(key: key, value: value) {
                unknown.append((key, value))
            }
        }
        configuration.customThemes = themeOrder.compactMap { themeDrafts[$0]?.resolved() }
        // A preset that names nothing, or names a relative shell or
        // directory, is a typo — kept out of the menu rather than offered as
        // something that will fail at spawn time.
        configuration.presets = presetOrder.compactMap { presetDrafts[$0] }.filter(\.isUsable)
        return (configuration, unknown)
    }

    /// Applies one key. Returns false when the key is not one of ours — or
    /// when it is ours but the value cannot be parsed at all, so the line
    /// lands in `unknown` and survives the next write verbatim: a typo the
    /// user can see and fix, not one silently replaced by the default. An
    /// out-of-range value that *does* parse is clamped, not rejected, so the
    /// key still counts as recognised and is rewritten in canonical form.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "font-family":
            fontFamily = value.isEmpty ? Self.systemFontFamily : value
        case "font-size":
            // The same clamp the ⌘+/⌘− path uses: below ~8pt the metrics
            // round to a degenerate cell.
            guard let size = Double(value) else { return false }
            fontSize = min(64, max(8, size))
        case "theme":
            // Not validated here: a custom theme may be defined further down
            // the same file, and the name is resolved when it is used.
            theme = value.isEmpty ? Theme.corta.name : value
        case "appearance":
            guard let parsed = Appearance(rawValue: value) else { return false }
            appearance = parsed
        case "columns":
            // Clamped to what a window can actually show: below the minimum
            // grid the window cannot be built, and an absurd value would open
            // a window larger than every display.
            guard let value = Int(value) else { return false }
            columns = min(500, max(20, value))
        case "rows":
            guard let value = Int(value) else { return false }
            rows = min(300, max(5, value))
        case "scrollback-lines":
            // Capped: scrollback is unbounded input and every unbounded
            // input needs a cap (`SECURITY.md` §3).
            guard let lines = Int(value) else { return false }
            scrollbackLines = min(1_000_000, max(0, lines))
        case "command-history-limit":
            guard let limit = Int(value) else { return false }
            commandHistoryLimit = min(10_000, max(0, limit))
        case "bell":
            guard let mode = BellMode(rawValue: value) else { return false }
            bell = mode
        case "notify-on-long-task":
            guard let parsed = Self.parseBool(value) else { return false }
            notifyOnLongTask = parsed
        case "notification-threshold":
            guard let seconds = Double(value) else { return false }
            notificationThreshold = max(1, seconds)
        case "open-file-command":
            // Validated when it is *set*, not only when it is run (U17). An
            // executable that is not an absolute path can never be launched
            // — resolving a bare name would mean consulting a `PATH` that the
            // user's shell, not Corta, controls — and finding that out at
            // click time, as a toast, is finding it out in the wrong place.
            // Malformed means the line is preserved and the default applies,
            // the same as every other unparseable value.
            guard Self.isUsableOpenFileCommand(value) else { return false }
            openFileCommand = value
        case "search-regex":
            guard let parsed = Self.parseBool(value) else { return false }
            searchRegex = parsed
        case "search-case-sensitive":
            guard let parsed = Self.parseBool(value) else { return false }
            searchCaseSensitive = parsed
        case "option-as-meta":
            guard let parsed = Self.parseBool(value) else { return false }
            optionAsMeta = parsed
        case "copy-on-select":
            guard let parsed = Self.parseBool(value) else { return false }
            copyOnSelect = parsed
        case "link-activation":
            guard let activation = LinkActivation(rawValue: value) else { return false }
            linkActivation = activation
        case "allow-clipboard-write":
            guard let parsed = Self.parseBool(value) else { return false }
            allowClipboardWrite = parsed
        case "directory-history":
            guard let parsed = Self.parseBool(value) else { return false }
            directoryHistory = parsed
        case "restore-windows":
            guard let parsed = Self.parseBool(value) else { return false }
            restoreWindows = parsed
        case "confirm-close":
            guard let parsed = Self.parseBool(value) else { return false }
            confirmClose = parsed
        case "update-auto-check":
            guard let parsed = Self.parseBool(value) else { return false }
            updateAutoCheck = parsed
        case "suggest-applications-folder":
            guard let parsed = Self.parseBool(value) else { return false }
            suggestApplicationsFolder = parsed
        default:
            return false
        }
        return true
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: - Custom themes (M7.6)

    /// A theme under construction: `theme.<name>.<variant>.<field>` keys
    /// arrive one at a time, and anything left unset inherits.
    private struct ThemeDraft {
        var name: String
        var displayName: String?
        /// The built-in this theme starts from, so a two-line theme is a
        /// legal theme. `theme.<name>.inherit = solarized`.
        var inherit: String?
        var dark = VariantDraft()
        var light = VariantDraft()

        struct VariantDraft {
            var foreground: SIMD4<Float>?
            var background: SIMD4<Float>?
            var cursor: SIMD4<Float>?
            /// Sparse: a theme may override one ANSI slot and leave fifteen.
            var ansi: [Int: SIMD4<Float>] = [:]
        }

        func resolved() -> Theme {
            let base = inherit.flatMap(Theme.named(_:)) ?? .corta
            return Theme(
                name: name,
                displayName: displayName ?? name,
                dark: Self.resolve(dark, base: base.dark),
                light: Self.resolve(light, base: base.light))
        }

        private static func resolve(_ draft: VariantDraft, base: Theme.Variant) -> Theme.Variant {
            var ansi = base.ansi
            for (index, color) in draft.ansi where index >= 0 && index < ansi.count {
                ansi[index] = color
            }
            return Theme.Variant(
                foreground: draft.foreground ?? base.foreground,
                background: draft.background ?? base.background,
                cursor: draft.cursor ?? base.cursor,
                ansi: ansi)
        }
    }

    /// `theme.<name>.<field>` and `theme.<name>.<dark|light>.<field>`.
    /// Returns false for a shape this does not recognise, so it lands in
    /// `unknown` and survives the round trip.
    /// `preset.<name>.<field>`. Unknown fields fall through to the unknown
    /// list, so a key from a newer version survives a write by this one — the
    /// same rule the theme keys follow.
    private static func applyPresetKey(
        _ key: String, value: String, drafts: inout [String: Preset], order: inout [String]
    ) -> Bool {
        let rest = key.dropFirst("preset.".count)
        guard let dot = rest.firstIndex(of: ".") else { return false }
        let name = String(rest[rest.startIndex..<dot])
        let field = String(rest[rest.index(after: dot)...])
        guard !name.isEmpty, !field.isEmpty else { return false }
        if drafts[name] == nil {
            drafts[name] = Preset(name: name)
            order.append(name)
        }
        return drafts[name]!.apply(field: field, value: value)
    }

    private static func applyThemeKey(
        _ key: String, value: String, drafts: inout [String: ThemeDraft], order: inout [String]
    ) -> Bool {
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return false }
        let name = parts[1]
        guard !name.isEmpty else { return false }
        if drafts[name] == nil {
            drafts[name] = ThemeDraft(name: name)
            order.append(name)
        }

        // `theme.<name>.name` and `theme.<name>.inherit` are theme-level.
        if parts.count == 3 {
            switch parts[2] {
            case "name":
                drafts[name]?.displayName = value
                return true
            case "inherit":
                drafts[name]?.inherit = value
                return true
            default:
                return false
            }
        }
        guard parts.count == 4, let isDark = variantIsDark(parts[2]), var draft = drafts[name]
        else { return false }
        let applied =
            isDark
            ? applyVariantField(parts[3], value: value, into: &draft.dark)
            : applyVariantField(parts[3], value: value, into: &draft.light)
        drafts[name] = draft
        return applied
    }

    private static func variantIsDark(_ text: String) -> Bool? {
        switch text {
        case "dark": return true
        case "light": return false
        default: return nil
        }
    }

    private static func applyVariantField(
        _ field: String, value: String, into draft: inout ThemeDraft.VariantDraft
    ) -> Bool {
        if field == "ansi" {
            // The whole table on one line, comma-separated. Shorter lists are
            // taken as a prefix, so `ansi = #000, #f00` overrides two slots.
            let colors = value.split(separator: ",").compactMap { Theme.color(String($0)) }
            guard !colors.isEmpty else { return false }
            for (index, color) in colors.enumerated() { draft.ansi[index] = color }
            return true
        }
        if field.hasPrefix("ansi"), let index = Int(field.dropFirst("ansi".count)) {
            guard let color = Theme.color(value) else { return false }
            draft.ansi[index] = color
            return true
        }
        guard let color = Theme.color(value) else { return false }
        switch field {
        case "foreground": draft.foreground = color
        case "background": draft.background = color
        case "cursor": draft.cursor = color
        default: return false
        }
        return true
    }

    // MARK: - Writing

    /// The file this configuration would be written as, with a header
    /// explaining that hand-edits are picked up — because they are, and a
    /// config file that does not say so invites the user to look for a
    /// hidden second store.
    func serialized(preserving unknown: [(String, String)] = []) -> String {
        var lines = [
            "# Corta configuration.",
            "#",
            "# This file is the single source of truth. The settings page edits it,",
            "# and an edit made here is picked up while Corta is running.",
            "",
            "# Appearance",
            "theme = \(theme)",
            "appearance = \(appearance.rawValue)",
            "font-family = \(fontFamily)",
            "font-size = \(Self.number(fontSize))",
            "",
            "# Terminal",
            "columns = \(columns)",
            "rows = \(rows)",
            "scrollback-lines = \(scrollbackLines)",
            "command-history-limit = \(commandHistoryLimit)",
            "bell = \(bell.rawValue)",
            "copy-on-select = \(copyOnSelect)",
            "link-activation = \(linkActivation.rawValue)",
            "option-as-meta = \(optionAsMeta)",
            "search-case-sensitive = \(searchCaseSensitive)",
            "search-regex = \(searchRegex)",
            "open-file-command = \(openFileCommand)",
            "allow-clipboard-write = \(allowClipboardWrite)",
            "directory-history = \(directoryHistory)",
            "restore-windows = \(restoreWindows)",
            "confirm-close = \(confirmClose)",
            "update-auto-check = \(updateAutoCheck)",
            "suggest-applications-folder = \(suggestApplicationsFolder)",
            "",
            "# Notifications",
            "notify-on-long-task = \(notifyOnLongTask)",
            "notification-threshold = \(Self.number(notificationThreshold))",
        ]
        if !presets.isEmpty {
            lines.append("")
            lines.append("# Presets (U16): a shell, a directory and a few variables.")
            for preset in presets { lines.append(contentsOf: preset.serializedLines) }
        }
        if !customThemes.isEmpty {
            lines.append("")
            lines.append("# Themes defined here. Anything left out is inherited from")
            lines.append("# `theme.<name>.inherit`, or from the built-in `corta` theme.")
            for theme in customThemes { lines.append(contentsOf: Self.themeLines(theme)) }
        }
        let overrides = keybindings.overriddenCommands
        if !overrides.isEmpty {
            lines.append("")
            lines.append("# Keyboard shortcuts. An empty value removes the binding.")
            for (command, shortcut) in overrides {
                lines.append("\(command.configurationKey) = \(shortcut?.text ?? "")")
            }
        }
        if !unknown.isEmpty {
            lines.append("")
            lines.append("# Written by a different version of Corta and kept verbatim.")
            for (key, value) in unknown { lines.append("\(key) = \(value)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One theme's block. Written in full rather than as a diff against what
    /// it inherits: a theme read back has already been resolved, and
    /// reconstructing the original sparse form would be guesswork.
    private static func themeLines(_ theme: Theme) -> [String] {
        var lines = ["", "theme.\(theme.name).name = \(theme.displayName)"]
        for (label, variant) in [("dark", theme.dark), ("light", theme.light)] {
            let prefix = "theme.\(theme.name).\(label)"
            lines.append("\(prefix).foreground = \(Theme.hex(variant.foreground))")
            lines.append("\(prefix).background = \(Theme.hex(variant.background))")
            lines.append("\(prefix).cursor = \(Theme.hex(variant.cursor))")
            lines.append("\(prefix).ansi = \(variant.ansi.map(Theme.hex).joined(separator: ", "))")
        }
        return lines
    }

    /// Trims a trailing `.0` so a whole number reads as one.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
