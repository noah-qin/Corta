// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CortaTerminal
import Foundation

/// Everything the settings page can change, and the file format it is
/// stored in.
///
/// One file is the source of truth (D10): the settings page edits and
/// re-reads it, and a hand-edit is as valid as a click, which is why this
/// type owns both values and serialisation.
///
/// `key = value` per line, `#` to end of line for comments — except a `#`
/// opening a value, which is a colour. Unknown keys survive a write, so a
/// newer Corta's file round-trips through an older one. Structured keys use
/// dotted prefixes: `theme.<name>.…`, `preset.<name>.…` and
/// `bind.<command>`.
nonisolated struct Configuration: Equatable, Sendable {
    /// Which of a theme's two variants is live.
    enum Appearance: String, CaseIterable, Sendable {
        /// Follow macOS, switching live when the system does.
        case auto
        case light
        case dark
    }

    /// What it takes to open a link.
    enum LinkActivation: String, CaseIterable, Sendable {
        /// ⌘-click: the modifier is the confirmation.
        case command
        /// A plain click opens it and hovering underlines it; a drag still
        /// selects.
        case click
    }

    /// Where the Quick Terminal's panel sits on its screen.
    enum QuickTerminalPosition: String, CaseIterable, Sendable {
        /// A band across the top edge, the width of the screen.
        case top
        case bottom
        /// A centred window, smaller than either band.
        case center
    }

    /// Which display the Quick Terminal opens on.
    enum QuickTerminalScreen: String, CaseIterable, Sendable {
        /// The screen under the pointer when the hotkey is pressed.
        case mouse
        /// `NSScreen.main`: the key window's screen, else the primary.
        case main
    }

    enum CursorShape: String, CaseIterable, Sendable {
        case block, bar, underline

        func style(blinking: Bool) -> CursorStyle {
            switch self {
            case .block: blinking ? .blinkingBlock : .block
            case .bar: blinking ? .blinkingBar : .bar
            case .underline: blinking ? .blinkingUnderline : .underline
            }
        }
    }

    enum InputSourceIndicatorMode: String, CaseIterable, Sendable {
        case auto, always, off
    }

    enum InputSourceIndicatorPosition: String, CaseIterable, Sendable {
        case toolbar, prompt
    }

    var inputSourceIndicatorPosition: InputSourceIndicatorPosition = .toolbar
    var inputSourceIndicator: InputSourceIndicatorMode = .auto
    /// Empty uses the subtle appearance-aware default styling.
    var inputSourceDirectColor: String = ""
    var inputSourceIMEColor: String = ""

    var statusBar = false
    var statusItems: Set<SystemMetrics.Item> = Set(SystemMetrics.Item.allCases)
    var statusNetworkInterface = "auto"
    var cursorShape: CursorShape = .block
    var cursorBlink: Bool = false
    var fontFamily: String = Configuration.systemFontFamily
    var fontSize: Double = 12
    var theme: String = Theme.corta.name
    var appearance: Appearance = .auto
    var scrollbackLines: Int = 10_000
    /// Caps `CommandRecordStore`'s structured command records per session,
    /// separately from `scrollbackLines`.
    var commandHistoryLimit: Int = CommandRecordStore.defaultCapacity
    /// The grid a new window opens with, in cells, so it holds across font
    /// changes.
    var columns: Int = 120
    var rows: Int = 30
    var bell: BellMode = .visual
    var notifyOnLongTask: Bool = false
    /// Seconds a command must run before its finish is worth a notification.
    var notificationThreshold: Double = 30
    /// A finished selection goes straight to the pasteboard, as on X11. On by
    /// default because it is not silent: the pane shows a toast
    /// (`TerminalView.showToast`).
    var copyOnSelect: Bool = true
    /// See `LinkActivation`.
    var linkActivation: LinkActivation = .command
    enum MouseOverrideModifier: String, CaseIterable, Sendable {
        case option, shift, control

        var flags: NSEvent.ModifierFlags {
            switch self {
            case .option: return .option
            case .shift: return .shift
            case .control: return .control
            }
        }

        var symbol: String {
            switch self {
            case .option: return "⌥"
            case .shift: return "⇧"
            case .control: return "⌃"
            }
        }
    }
    var mouseOverrideModifier: MouseOverrideModifier = .option
    /// ⌥ sends ESC plus the base character, as readline expects. Off by
    /// default: on a Mac, Option types é, ø and dead keys.
    var optionAsMeta: Bool = false

    /// Case-sensitive search. The search bar's toggle writes it, so the choice
    /// survives a restart.
    var searchCaseSensitive: Bool = false

    /// Regex search; the bar's toggle writes it too.
    var searchRegex: Bool = false

    /// Opens a `path:line` reference, substituting `{file}`, `{line}` and
    /// `{column}`. Empty disables opening output-derived files.
    var openFileCommand: String = ""

    /// Whether an `open-file-command` template can run: empty, or an absolute
    /// executable path with only known placeholders (unknown ones would pass
    /// through literally). Splits on any whitespace, as `openFileArguments`
    /// does, so a tab can't pass here and fail at `Process.run`.
    static func isUsableOpenFileCommand(_ template: String) -> Bool {
        // A newline would serialise as a second config line — a stray key. The
        // settings field takes pastes, so trimming isn't enough.
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
    /// Whether OSC 52 may write the pasteboard. Off by default
    /// (`SECURITY.md` §2.6): any output could plant `rm -rf ~` for a later
    /// paste. It is the only clipboard route inside tmux or ssh; reading stays
    /// unavailable under every setting (§6).
    var allowClipboardWrite: Bool = false
    /// Whether visited directories (OSC 7) are kept for the directory
    /// switcher. On by default: nothing leaves the app. The history lives in
    /// `DirectoryHistory`'s own file; clearing it is a Settings action.
    var directoryHistory: Bool = true
    var directoryCompletion: Bool = true
    var commandStatusMarks: Bool = true
    /// Reopen last run's windows, splits and directories.
    var restoreWindows: Bool = true
    /// Ask before closing a pane with a running child process.
    var confirmClose: Bool = true
    /// Sparkle's background check (`SUScheduledCheckInterval`); Check for
    /// Updates… works either way.
    var updateAutoCheck: Bool = true
    /// Offer to move Corta into /Applications (`ApplicationsFolderMover`);
    /// off once the user moves it or declines.
    var suggestApplicationsFolder: Bool = true

    /// Whether a global hotkey summons the Quick Terminal. Off by default: the
    /// key is claimed system-wide, and another tool may own it.
    var quickTerminal: Bool = false
    /// The hotkey in `bind.*` notation, matched by ANSI key position
    /// (`GlobalHotKey`), not by the character typed.
    var quickTerminalKey: Shortcut? = Shortcut.parse(Configuration.defaultQuickTerminalKey)
    var quickTerminalPosition: QuickTerminalPosition = .top
    var quickTerminalScreen: QuickTerminalScreen = .mouse
    /// Secure Keyboard Entry while a Corta window is key (`SecureInput`). Off
    /// by default: it also blocks accessibility tools and text expanders.
    var secureKeyboardEntry: Bool = false

    /// Themes defined in the config file itself, in file order.
    var customThemes: [Theme] = []

    /// Presets, in file order, which is menu order.
    var presets: [Preset] = []
    var keybindings = Keybindings()

    /// Means `NSFont.monospacedSystemFont`, tracking the OS.
    static let systemFontFamily = "system"

    /// The default hotkey: ⌥Space, the Mac's usual launcher key.
    static let defaultQuickTerminalKey = "alt+space"

    init() {}

    // MARK: - Parsing

    /// Parses a config file. Bad lines are skipped, never fatal. Returns the
    /// keys it did not recognise, including recognised keys with unparseable
    /// values (`font-size = banana`), so `serialized(preserving:)` writes them
    /// back untouched.
    static func parse(_ text: String) -> (configuration: Configuration, unknown: [(String, String)]) {
        var configuration = Configuration()
        var unknown: [(String, String)] = []
        // Theme keys accumulate into drafts resolved after the whole file, so a
        // theme can inherit from one defined further down.
        var themeDrafts: [String: ThemeDraft] = [:]
        var themeOrder: [String] = []
        var presetDrafts: [String: Preset] = [:]
        var presetOrder: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Split key from value before stripping comments, so a value's leading
            // `#` stays a colour (`background = #101018`).
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
                    // Empty unbinds; malformed keeps the default rather than guess.
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
        // An empty preset, or one with a relative shell or directory, is a typo
        // that would fail at spawn.
        configuration.presets = presetOrder.compactMap { presetDrafts[$0] }.filter(\.isUsable)
        return (configuration, unknown)
    }

    /// Applies one key; false when it isn't ours or its value doesn't parse,
    /// so the line survives verbatim for the user to fix. A parseable
    /// out-of-range value is clamped and rewritten canonically.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "input-source-indicator":
            guard let mode = InputSourceIndicatorMode(rawValue: value) else { return false }
            inputSourceIndicator = mode
        case "input-source-indicator-position":
            guard let position = InputSourceIndicatorPosition(rawValue: value) else { return false }
            inputSourceIndicatorPosition = position
        case "input-source-direct-color", "input-source-ime-color":
            guard let color = value.isEmpty ? "" : Theme.color(value).map(Theme.hex) else { return false }
            if key == "input-source-direct-color" { inputSourceDirectColor = color }
            else { inputSourceIMEColor = color }
        case "status-bar":
            guard let enabled = Self.parseBool(value) else { return false }
            statusBar = enabled
        case "status-items":
            let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let items = names.compactMap(SystemMetrics.Item.init(rawValue:))
            guard items.count == names.count else { return false }
            statusItems = Set(items)
        case "status-network-interface":
            guard !value.isEmpty, value.count < 32,
                value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return false }
            statusNetworkInterface = value
        case "cursor-shape":
            guard let shape = CursorShape(rawValue: value) else { return false }
            cursorShape = shape
        case "cursor-blink":
            guard let blink = Self.parseBool(value) else { return false }
            cursorBlink = blink
        case "font-family":
            // Legacy family names migrate to the single supported face.
            fontFamily = Self.systemFontFamily
        case "font-size":
            // The ⌘+/⌘− clamp: below ~8pt the cell degenerates.
            guard let size = Double(value) else { return false }
            fontSize = min(64, max(8, size))
        case "theme":
            // Resolved at use: a custom theme may be defined further down.
            theme = value.isEmpty ? Theme.corta.name : value
        case "appearance":
            guard let parsed = Appearance(rawValue: value) else { return false }
            appearance = parsed
        case "columns":
            // Clamped between the minimum grid and a sane maximum.
            guard let value = Int(value) else { return false }
            columns = min(500, max(20, value))
        case "rows":
            guard let value = Int(value) else { return false }
            rows = min(300, max(5, value))
        case "scrollback-lines":
            // Every unbounded input needs a cap (`SECURITY.md` §3).
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
            // Validated when set, not at click time. A bare name would resolve
            // through a `PATH` the user's shell controls, not Corta.
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
        case "mouse-override-modifier":
            guard let modifier = MouseOverrideModifier(rawValue: value) else { return false }
            mouseOverrideModifier = modifier
        case "link-activation":
            guard let activation = LinkActivation(rawValue: value) else { return false }
            linkActivation = activation
        case "allow-clipboard-write":
            guard let parsed = Self.parseBool(value) else { return false }
            allowClipboardWrite = parsed
        case "directory-completion":
            guard let parsed = Self.parseBool(value) else { return false }
            directoryCompletion = parsed
        case "command-status-marks":
            guard let parsed = Self.parseBool(value) else { return false }
            commandStatusMarks = parsed
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
        case "quick-terminal":
            guard let parsed = Self.parseBool(value) else { return false }
            quickTerminal = parsed
        case "quick-terminal-key":
            // Empty means no hotkey (menu and palette only). A shortcut with no
            // modifier is refused: it would swallow the key system-wide.
            if value.isEmpty {
                quickTerminalKey = nil
            } else {
                guard let shortcut = Shortcut.parse(value), GlobalHotKey.isRegistrable(shortcut)
                else { return false }
                quickTerminalKey = shortcut
            }
        case "quick-terminal-position":
            guard let parsed = QuickTerminalPosition(rawValue: value) else { return false }
            quickTerminalPosition = parsed
        case "quick-terminal-screen":
            guard let parsed = QuickTerminalScreen(rawValue: value) else { return false }
            quickTerminalScreen = parsed
        case "secure-keyboard-entry":
            guard let parsed = Self.parseBool(value) else { return false }
            secureKeyboardEntry = parsed
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

    // MARK: - Custom themes

    /// A theme under construction; unset fields inherit.
    private struct ThemeDraft {
        var name: String
        var displayName: String?
        /// The built-in to start from: `theme.<name>.inherit = solarized`.
        var inherit: String?
        var dark = VariantDraft()
        var light = VariantDraft()

        struct VariantDraft {
            var foreground: SIMD4<Float>?
            var background: SIMD4<Float>?
            var cursor: SIMD4<Float>?
            /// Sparse: a theme may override one slot.
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

    /// `preset.<name>.<field>`. Unknown fields are returned false and
    /// survive the write, as theme keys do.
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

    /// `theme.<name>.<field>` and `theme.<name>.<dark|light>.<field>`;
    /// false for an unknown shape, which survives the round trip.
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
            // Comma-separated; a shorter list is a prefix (`ansi = #000, #f00`).
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

    /// The file text, with a header saying hand-edits are picked up, so no
    /// one looks for a hidden second store.
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
            "input-source-indicator = \(inputSourceIndicator.rawValue)",
            "input-source-indicator-position = \(inputSourceIndicatorPosition.rawValue)",
            "input-source-direct-color = \(inputSourceDirectColor)",
            "input-source-ime-color = \(inputSourceIMEColor)",
            "status-bar = \(statusBar)",
            "status-items = \(SystemMetrics.Item.allCases.filter { statusItems.contains($0) }.map(\.rawValue).joined(separator: ","))",
            "status-network-interface = \(statusNetworkInterface)",
            "cursor-shape = \(cursorShape.rawValue)",
            "cursor-blink = \(cursorBlink)",
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
            "mouse-override-modifier = \(mouseOverrideModifier.rawValue)",
            "option-as-meta = \(optionAsMeta)",
            "search-case-sensitive = \(searchCaseSensitive)",
            "search-regex = \(searchRegex)",
            "open-file-command = \(openFileCommand)",
            "allow-clipboard-write = \(allowClipboardWrite)",
            "directory-history = \(directoryHistory)",
            "directory-completion = \(directoryCompletion)",
            "command-status-marks = \(commandStatusMarks)",
            "restore-windows = \(restoreWindows)",
            "confirm-close = \(confirmClose)",
            "update-auto-check = \(updateAutoCheck)",
            "suggest-applications-folder = \(suggestApplicationsFolder)",
            "secure-keyboard-entry = \(secureKeyboardEntry)",
            "",
            "# Quick Terminal: a panel summoned by a system-wide hotkey.",
            "quick-terminal = \(quickTerminal)",
            "quick-terminal-key = \(quickTerminalKey?.text ?? "")",
            "quick-terminal-position = \(quickTerminalPosition.rawValue)",
            "quick-terminal-screen = \(quickTerminalScreen.rawValue)",
            "",
            "# Notifications",
            "notify-on-long-task = \(notifyOnLongTask)",
            "notification-threshold = \(Self.number(notificationThreshold))",
        ]
        if !presets.isEmpty {
            lines.append("")
            lines.append("# Presets: a shell, a directory and a few variables.")
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

    /// One theme, written in full: the sparse original can't be recovered
    /// after resolution.
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

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
