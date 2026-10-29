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

/// One keyboard shortcut, in the two pieces AppKit wants: the key equivalent
/// and the modifier mask.
///
/// Parsed from and written back as `cmd+shift+d` — the notation people
/// already type into every other terminal's config, and the one that survives
/// a round trip through a text file without quoting rules.
nonisolated struct Shortcut: Equatable, Sendable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The named keys, in both directions. Arrow and navigation keys reach a
    /// menu item as private-use scalars, which nobody can type into a config
    /// file — hence the table.
    private static let namedKeys: [(name: String, key: String)] = [
        ("up", String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        ("down", String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        ("left", String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        ("right", String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        ("home", String(UnicodeScalar(NSHomeFunctionKey)!)),
        ("end", String(UnicodeScalar(NSEndFunctionKey)!)),
        ("pageup", String(UnicodeScalar(NSPageUpFunctionKey)!)),
        ("pagedown", String(UnicodeScalar(NSPageDownFunctionKey)!)),
        ("return", "\r"),
        ("enter", "\r"),
        ("tab", "\t"),
        ("space", " "),
        ("escape", "\u{1B}"),
        ("delete", "\u{8}"),
    ]

    private static let namedModifiers: [(name: String, flag: NSEvent.ModifierFlags)] = [
        ("cmd", .command), ("command", .command),
        ("ctrl", .control), ("control", .control),
        ("alt", .option), ("opt", .option), ("option", .option),
        ("shift", .shift),
    ]

    /// `cmd+shift+d`, `ctrl+alt+left`, `cmd+,`. Case-insensitive; an empty
    /// string means "no shortcut", which is how a binding is removed.
    static func parse(_ text: String) -> Shortcut? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        // Split on `+`, but the last component may *be* `+`, so keep the tail
        // whatever it looks like.
        var parts = trimmed.components(separatedBy: "+")
        if parts.count > 1, parts.last?.isEmpty == true {
            parts.removeLast()
            parts[parts.count - 1] = "+"
        }
        guard let last = parts.popLast() else { return nil }
        for part in parts {
            guard let flag = namedModifiers.first(where: { $0.name == part })?.flag
            else { return nil }
            modifiers.insert(flag)
        }
        if let named = namedKeys.first(where: { $0.name == last })?.key {
            return Shortcut(named, modifiers)
        }
        guard last.count == 1 else { return nil }
        return Shortcut(last, modifiers)
    }

    /// The config-file spelling, modifiers in a fixed order so a round trip
    /// is stable.
    var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.namedKeys.first { $0.key == key }?.name ?? key)
        return parts.joined(separator: "+")
    }

    /// What a menu item shows. AppKit renders the modifier glyphs itself from
    /// `keyEquivalentModifierMask`, so this is only used by the command
    /// palette, which draws its own rows.
    var displayText: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + Self.keyGlyph(for: key)
    }

    /// The key as macOS spells it in a menu: `←`, `⇞`, `⏎`, `⎋`.
    ///
    /// The config-file name uppercased gave `⌥⌘LEFT` and `⌃⌘RIGHT` — legible,
    /// and not what any Mac shows anywhere. Every one of these keys has a
    /// glyph the system uses in its own menus, and a palette that spells them
    /// out is a palette whose shortcuts do not match the menu bar's next to
    /// it. A single letter still uppercases, because that is also what AppKit
    /// draws (`menuKeyEquivalent`).
    static func keyGlyph(for key: String) -> String {
        if let glyph = keyGlyphs.first(where: { $0.key == key })?.glyph { return glyph }
        return (namedKeys.first { $0.key == key }?.name ?? key).uppercased()
    }

    private static let keyGlyphs: [(key: String, glyph: String)] = [
        (String(UnicodeScalar(NSUpArrowFunctionKey)!), "↑"),
        (String(UnicodeScalar(NSDownArrowFunctionKey)!), "↓"),
        (String(UnicodeScalar(NSLeftArrowFunctionKey)!), "←"),
        (String(UnicodeScalar(NSRightArrowFunctionKey)!), "→"),
        (String(UnicodeScalar(NSHomeFunctionKey)!), "↖"),
        (String(UnicodeScalar(NSEndFunctionKey)!), "↘"),
        (String(UnicodeScalar(NSPageUpFunctionKey)!), "⇞"),
        (String(UnicodeScalar(NSPageDownFunctionKey)!), "⇟"),
        ("\r", "⏎"),
        ("\t", "⇥"),
        (" ", "␣"),
        ("\u{1B}", "⎋"),
        ("\u{8}", "⌫"),
    ]

    /// AppKit's convention: an uppercase key equivalent *is* the shift
    /// modifier, and a menu item that sets both shows "⇧⇧". Normalises to the
    /// uppercase-letter form for single letters, which is what the menu's own
    /// items use.
    var menuKeyEquivalent: String {
        guard modifiers.contains(.shift), key.count == 1, key.first?.isLetter == true
        else { return key }
        return key.uppercased()
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        guard key.count == 1, key.first?.isLetter == true else { return modifiers }
        return modifiers.subtracting(.shift)
    }
}

/// Everything Corta can be asked to do that is worth a key, a menu item, or a
/// row in the command palette.
///
/// One table, three consumers. A shortcut in a nib and an action in
/// whichever controller implements it cannot be enumerated — nothing could
/// rebind them and a palette would have nothing to list. The table is the
/// single place all three read from, so a command added here appears in the
/// menus, in the palette and in the config file at once.
nonisolated enum TerminalCommand: String, CaseIterable, Sendable {
    case newWindow = "new-window"
    case newTab = "new-tab"
    case previousTab = "previous-tab"
    case nextTab = "next-tab"
    case renameTab = "rename-tab"
    case close
    case openProject = "open-project"
    case toggleSpace = "toggle-space"
    case splitRight = "split-right"
    case splitDown = "split-down"
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case focusUp = "focus-up"
    case focusDown = "focus-down"
    case growPaneHorizontally = "grow-pane-horizontally"
    case shrinkPaneHorizontally = "shrink-pane-horizontally"
    case growPaneVertically = "grow-pane-vertically"
    case shrinkPaneVertically = "shrink-pane-vertically"
    case equalizePanes = "equalize-panes"
    case zoomPane = "zoom-pane"
    case reopenClosedPane = "reopen-closed-pane"
    case increaseFontSize = "increase-font-size"
    case decreaseFontSize = "decrease-font-size"
    case resetFontSize = "reset-font-size"
    case find
    case copy
    case paste
    case selectAll = "select-all"
    case scrollPageUp = "scroll-page-up"
    case scrollPageDown = "scroll-page-down"
    case scrollToTop = "scroll-to-top"
    case scrollToBottom = "scroll-to-bottom"
    case previousCommand = "previous-command"
    case nextCommand = "next-command"
    case previousFailedCommand = "previous-failed-command"
    case nextFailedCommand = "next-failed-command"
    case copyLastCommandOutput = "copy-last-command-output"
    case snapshotRunningCommandOutput = "snapshot-running-command-output"
    case exportCommandOutput = "export-command-output"
    case openFileReferenceInCommand = "open-file-reference-in-command"
    case revealWorkingDirectory = "reveal-working-directory"
    case copyWorkingDirectoryPath = "copy-working-directory-path"
    case changeDirectoryToParent = "change-directory-to-parent"
    case changeDirectoryToProjectRoot = "change-directory-to-project-root"
    case openParentDirectoryInNewPane = "open-parent-directory-in-new-pane"
    case openProjectRootInNewPane = "open-project-root-in-new-pane"
    case searchCommandHistory = "search-command-history"
    case exportText = "export-text"
    case clearScreen = "clear-screen"
    case clearHistory = "clear-history"
    case resetTerminal = "reset-terminal"
    case reconnectRemote = "reconnect-remote"
    case browseRemoteFiles = "browse-remote-files"
    case quickTerminal = "quick-terminal"
    case secureKeyboardEntry = "secure-keyboard-entry"
    case settings
    case commandPalette = "command-palette"

    /// What the menus and the palette call it.
    var title: String {
        switch self {
        case .newWindow: return L10n.text("command.newWindow")
        case .newTab: return L10n.text("command.newTab")
        case .previousTab: return L10n.text("command.previousTab")
        case .nextTab: return L10n.text("command.nextTab")
        case .renameTab: return L10n.text("command.renameTab")
        case .close: return L10n.text("command.close")
        case .openProject: return L10n.text("command.openProject")
        case .toggleSpace: return L10n.text("command.toggleSpace")
        case .splitRight: return L10n.text("command.splitRight")
        case .splitDown: return L10n.text("command.splitDown")
        case .focusLeft: return L10n.text("command.focusLeft")
        case .focusRight: return L10n.text("command.focusRight")
        case .focusUp: return L10n.text("command.focusUp")
        case .focusDown: return L10n.text("command.focusDown")
        case .growPaneHorizontally: return L10n.text("command.growPaneHorizontally")
        case .shrinkPaneHorizontally: return L10n.text("command.shrinkPaneHorizontally")
        case .growPaneVertically: return L10n.text("command.growPaneVertically")
        case .shrinkPaneVertically: return L10n.text("command.shrinkPaneVertically")
        case .equalizePanes: return L10n.text("command.equalizePanes")
        case .zoomPane: return L10n.text("command.zoomPane")
        case .reopenClosedPane: return L10n.text("command.reopenClosedPane")
        case .increaseFontSize: return L10n.text("command.increaseFontSize")
        case .decreaseFontSize: return L10n.text("command.decreaseFontSize")
        case .resetFontSize: return L10n.text("command.resetFontSize")
        case .find: return L10n.text("command.find")
        case .copy: return L10n.text("common.copy")
        case .paste: return L10n.text("common.paste")
        case .selectAll: return L10n.text("common.selectAll")
        case .scrollPageUp: return L10n.text("command.scrollPageUp")
        case .scrollPageDown: return L10n.text("command.scrollPageDown")
        case .scrollToTop: return L10n.text("command.scrollToTop")
        case .scrollToBottom: return L10n.text("command.scrollToBottom")
        case .previousCommand: return L10n.text("command.previousCommand")
        case .nextCommand: return L10n.text("command.nextCommand")
        case .previousFailedCommand: return L10n.text("command.previousFailedCommand")
        case .nextFailedCommand: return L10n.text("command.nextFailedCommand")
        case .copyLastCommandOutput: return L10n.text("command.copyLastCommandOutput")
        case .snapshotRunningCommandOutput:
            return L10n.text("command.snapshotRunningCommandOutput")
        case .exportCommandOutput: return L10n.text("command.exportCommandOutput")
        case .openFileReferenceInCommand:
            return L10n.text("command.openFileReferenceInCommand")
        case .revealWorkingDirectory: return L10n.text("command.revealWorkingDirectory")
        case .copyWorkingDirectoryPath: return L10n.text("command.copyWorkingDirectoryPath")
        case .changeDirectoryToParent: return L10n.text("command.changeDirectoryToParent")
        case .changeDirectoryToProjectRoot:
            return L10n.text("command.changeDirectoryToProjectRoot")
        case .openParentDirectoryInNewPane:
            return L10n.text("command.openParentDirectoryInNewPane")
        case .openProjectRootInNewPane:
            return L10n.text("command.openProjectRootInNewPane")
        case .searchCommandHistory: return L10n.text("command.searchCommandHistory")
        case .exportText: return L10n.text("command.exportText")
        case .clearScreen: return L10n.text("command.clearScreen")
        case .clearHistory: return L10n.text("command.clearHistory")
        case .resetTerminal: return L10n.text("command.resetTerminal")
        case .reconnectRemote: return L10n.text("command.reconnectRemote")
        case .browseRemoteFiles: return L10n.text("command.browseRemoteFiles")
        case .quickTerminal: return L10n.text("command.quickTerminal")
        case .secureKeyboardEntry: return L10n.text("command.secureKeyboardEntry")
        case .settings: return L10n.text("command.settings")
        case .commandPalette: return L10n.text("command.commandPalette")
        }
    }

    /// The message sent through the responder chain. Sharing selectors with
    /// AppKit's standard items is deliberate: rebinding then means rewriting
    /// one menu item's key equivalent, not intercepting keys behind AppKit's
    /// back.
    var action: Selector {
        switch self {
        case .newWindow: return #selector(AppDelegate.newDocument(_:))
        case .newTab: return #selector(AppDelegate.newTab(_:))
        case .previousTab: return #selector(SplitViewController.selectPreviousCortaTab(_:))
        case .nextTab: return #selector(SplitViewController.selectNextCortaTab(_:))
        case .renameTab: return #selector(SplitViewController.renameCurrentTab(_:))
        case .close: return #selector(SplitViewController.performClose(_:))
        case .openProject: return #selector(SplitViewController.openSpaceProject(_:))
        case .toggleSpace: return #selector(SplitViewController.toggleSpaceMode(_:))
        case .splitRight: return #selector(SplitViewController.splitRight(_:))
        case .splitDown: return #selector(SplitViewController.splitDown(_:))
        case .focusLeft: return #selector(SplitViewController.moveFocusLeft(_:))
        case .focusRight: return #selector(SplitViewController.moveFocusRight(_:))
        case .focusUp: return #selector(SplitViewController.moveFocusUp(_:))
        case .focusDown: return #selector(SplitViewController.moveFocusDown(_:))
        case .growPaneHorizontally:
            return #selector(SplitViewController.growPaneHorizontally(_:))
        case .shrinkPaneHorizontally:
            return #selector(SplitViewController.shrinkPaneHorizontally(_:))
        case .growPaneVertically: return #selector(SplitViewController.growPaneVertically(_:))
        case .shrinkPaneVertically:
            return #selector(SplitViewController.shrinkPaneVertically(_:))
        case .equalizePanes: return #selector(SplitViewController.equalizePanes(_:))
        case .zoomPane: return #selector(SplitViewController.toggleZoomPane(_:))
        case .reopenClosedPane: return #selector(SplitViewController.reopenClosedPane(_:))
        case .increaseFontSize: return #selector(PaneCommands.increaseFontSize(_:))
        case .decreaseFontSize: return #selector(PaneCommands.decreaseFontSize(_:))
        case .resetFontSize: return #selector(PaneCommands.resetFontSize(_:))
        case .find: return #selector(PaneSearch.performFindPanelAction(_:))
        case .copy: return #selector(PaneCommands.copy(_:))
        case .paste: return #selector(PaneCommands.paste(_:))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        case .scrollPageUp: return #selector(PanePointer.scrollHistoryPageUp(_:))
        case .scrollPageDown: return #selector(PanePointer.scrollHistoryPageDown(_:))
        case .scrollToTop: return #selector(PanePointer.scrollHistoryToTop(_:))
        case .scrollToBottom: return #selector(PanePointer.scrollHistoryToBottom(_:))
        case .previousCommand: return #selector(PaneShellIntegration.jumpToPreviousCommand(_:))
        case .nextCommand: return #selector(PaneShellIntegration.jumpToNextCommand(_:))
        case .previousFailedCommand:
            return #selector(PaneShellIntegration.jumpToPreviousFailedCommand(_:))
        case .nextFailedCommand: return #selector(PaneShellIntegration.jumpToNextFailedCommand(_:))
        case .copyLastCommandOutput:
            return #selector(PaneShellIntegration.copyLastCommandOutput(_:))
        case .snapshotRunningCommandOutput:
            return #selector(PaneShellIntegration.snapshotRunningCommandOutput(_:))
        case .exportCommandOutput: return #selector(PaneCommands.exportCommandOutput(_:))
        case .openFileReferenceInCommand:
            return #selector(PaneShellIntegration.openFileReferenceInCommand(_:))
        case .revealWorkingDirectory:
            return #selector(PaneCommands.revealWorkingDirectoryInFinder(_:))
        case .copyWorkingDirectoryPath:
            return #selector(PaneCommands.copyWorkingDirectoryPath(_:))
        case .changeDirectoryToParent:
            return #selector(PaneCommands.changeDirectoryToParent(_:))
        case .changeDirectoryToProjectRoot:
            return #selector(PaneCommands.changeDirectoryToProjectRoot(_:))
        case .openParentDirectoryInNewPane:
            return #selector(PaneCommands.openParentDirectoryInNewPane(_:))
        case .openProjectRootInNewPane:
            return #selector(PaneCommands.openProjectRootInNewPane(_:))
        case .searchCommandHistory: return #selector(PaneShellIntegration.searchCommandHistory(_:))
        case .exportText: return #selector(PaneCommands.exportText(_:))
        case .clearScreen: return #selector(PaneCommands.clearScreen(_:))
        case .clearHistory: return #selector(PaneCommands.clearHistory(_:))
        case .resetTerminal: return #selector(PaneCommands.resetTerminal(_:))
        case .reconnectRemote: return #selector(PaneRemote.reconnectRemote(_:))
        case .browseRemoteFiles: return #selector(PaneRemote.browseRemoteFiles(_:))
        case .quickTerminal: return #selector(AppDelegate.toggleQuickTerminal(_:))
        case .secureKeyboardEntry: return #selector(AppDelegate.toggleSecureKeyboardEntry(_:))
        case .settings: return #selector(AppDelegate.showSettings(_:))
        case .commandPalette: return #selector(AppDelegate.showCommandPalette(_:))
        }
    }

    /// The config-file key this command's binding is written under.
    var configurationKey: String { "bind.\(rawValue)" }

    /// The menu item tag that tells this command apart from others sharing
    /// its action. Only the Find family needs one: four menu items send
    /// `performFindPanelAction:` and are distinguished by tag, so rebinding
    /// "Find…" must not also rebind "Find Next".
    var menuTag: Int? {
        switch self {
        case .find: return 1
        default: return nil
        }
    }
}

/// The shortcut table in force: the defaults, with the config file's
/// overrides applied.
///
/// An override to the empty string removes the binding rather than restoring
/// the default — a user who unbinds ⌘W because a TUI wants it must not have
/// it handed back.
nonisolated struct Keybindings: Equatable, Sendable {
    /// Only the commands the config file mentions. Everything else answers
    /// from `defaultShortcut`, so the file stays short and a changed default
    /// reaches users who never overrode it.
    private var overrides: [TerminalCommand: Shortcut?] = [:]

    init() {}

    subscript(command: TerminalCommand) -> Shortcut? {
        get { overrides[command] ?? command.defaultShortcut }
        set { overrides[command] = .some(newValue) }
    }

    mutating func reset(_ command: TerminalCommand) { overrides.removeValue(forKey: command) }

    /// The overrides, in `TerminalCommand.allCases` order, for serialisation.
    var overriddenCommands: [(TerminalCommand, Shortcut?)] {
        TerminalCommand.allCases.compactMap { command in
            overrides[command].map { (command, $0) }
        }
    }
}

/// The command palette's groups, in the order it lists them.
nonisolated enum CommandCategory: String, CaseIterable, Sendable {
    case window
    case panes
    case view
    case edit
    case terminal
    case app

    var title: String { L10n.text("commandPalette.category.\(rawValue)") }
}

nonisolated extension Shortcut {
    /// Whether a key event is this shortcut.
    ///
    /// AppKit matches key equivalents for *menu items* only. The few places
    /// `TerminalView.keyDown` still has to recognise a shortcut itself —
    /// paste, the search bar, the scrollback jumps — ask this rather than
    /// compare against a literal, which would make every one of them a
    /// second, invisible binding: rebinding the command would leave the
    /// literal working, and unbinding it would not stop the literal at all.
    ///
    /// The key comes from `charactersIgnoringModifiers`, so a shifted letter
    /// arrives uppercase and folds back through `lowercased()`. A key whose
    /// *symbol* changes under Shift (⇧= is `+`) therefore matches on its
    /// unshifted spelling only — the same limit AppKit's own key-equivalent
    /// matching has, and the reason `shift+=` and `+` are two ways to write
    /// one binding rather than two bindings.
    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == modifiers.intersection(relevant),
            let characters = event.charactersIgnoringModifiers
        else { return false }
        return characters.lowercased() == key.lowercased()
    }
}

nonisolated extension Keybindings {
    /// Every command bound to `event`, in `TerminalCommand.allCases` order.
    ///
    /// Nothing rejects a collision: the config file is hand-edited, and two
    /// `bind.` lines may name one keystroke. The resolution is defined rather
    /// than arbitrary — where AppKit decides (a menu key equivalent) the
    /// winner is the first matching item in menu-bar traversal order, and
    /// where Corta decides (the `keyDown` fallbacks) it is the first command
    /// in this list. A collision is still a collision, and Help ▸ Keyboard
    /// Shortcuts is where it shows: the same key printed against two rows is
    /// what tells a user they typed one binding twice.
    func commands(boundTo event: NSEvent) -> [TerminalCommand] {
        TerminalCommand.allCases.filter { self[$0]?.matches(event) == true }
    }
}
