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
    /// uppercase-letter form for single letters, which is what the storyboard
    /// items already use.
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
/// row in the command palette (M7.8).
///
/// One table, three consumers. Before this, a shortcut lived in the
/// storyboard, its action lived in whichever controller implemented it, and
/// nothing could enumerate the set — which is why the shortcuts could not be
/// rebound and why there was nothing for a palette to list. The table is the
/// single place all three read from, so a command added here appears in the
/// menus, in the palette and in the config file at once.
nonisolated enum TerminalCommand: String, CaseIterable, Sendable {
    case newWindow = "new-window"
    case newTab = "new-tab"
    case close
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
    case settings
    case commandPalette = "command-palette"

    /// What the menus and the palette call it.
    var title: String {
        switch self {
        case .newWindow: return L10n.text("command.newWindow")
        case .newTab: return L10n.text("command.newTab")
        case .close: return L10n.text("command.close")
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
        case .settings: return L10n.text("command.settings")
        case .commandPalette: return L10n.text("command.commandPalette")
        }
    }

    /// The message sent through the responder chain. Sharing selectors with
    /// the storyboard's items is deliberate: rebinding then means rewriting
    /// one menu item's key equivalent, not intercepting keys behind AppKit's
    /// back.
    var action: Selector {
        switch self {
        case .newWindow: return #selector(AppDelegate.newDocument(_:))
        case .newTab: return #selector(AppDelegate.newTab(_:))
        case .close: return #selector(SplitViewController.performClose(_:))
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
        case .increaseFontSize: return #selector(ViewController.increaseFontSize(_:))
        case .decreaseFontSize: return #selector(ViewController.decreaseFontSize(_:))
        case .resetFontSize: return #selector(ViewController.resetFontSize(_:))
        case .find: return #selector(ViewController.performFindPanelAction(_:))
        case .copy: return #selector(ViewController.copy(_:))
        case .paste: return #selector(ViewController.paste(_:))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        case .scrollPageUp: return #selector(ViewController.scrollHistoryPageUp(_:))
        case .scrollPageDown: return #selector(ViewController.scrollHistoryPageDown(_:))
        case .scrollToTop: return #selector(ViewController.scrollHistoryToTop(_:))
        case .scrollToBottom: return #selector(ViewController.scrollHistoryToBottom(_:))
        case .previousCommand: return #selector(ViewController.jumpToPreviousCommand(_:))
        case .nextCommand: return #selector(ViewController.jumpToNextCommand(_:))
        case .previousFailedCommand:
            return #selector(ViewController.jumpToPreviousFailedCommand(_:))
        case .nextFailedCommand: return #selector(ViewController.jumpToNextFailedCommand(_:))
        case .copyLastCommandOutput:
            return #selector(ViewController.copyLastCommandOutput(_:))
        case .snapshotRunningCommandOutput:
            return #selector(ViewController.snapshotRunningCommandOutput(_:))
        case .exportCommandOutput: return #selector(ViewController.exportCommandOutput(_:))
        case .openFileReferenceInCommand:
            return #selector(ViewController.openFileReferenceInCommand(_:))
        case .revealWorkingDirectory:
            return #selector(ViewController.revealWorkingDirectoryInFinder(_:))
        case .copyWorkingDirectoryPath:
            return #selector(ViewController.copyWorkingDirectoryPath(_:))
        case .changeDirectoryToParent:
            return #selector(ViewController.changeDirectoryToParent(_:))
        case .changeDirectoryToProjectRoot:
            return #selector(ViewController.changeDirectoryToProjectRoot(_:))
        case .openParentDirectoryInNewPane:
            return #selector(ViewController.openParentDirectoryInNewPane(_:))
        case .openProjectRootInNewPane:
            return #selector(ViewController.openProjectRootInNewPane(_:))
        case .searchCommandHistory: return #selector(ViewController.searchCommandHistory(_:))
        case .exportText: return #selector(ViewController.exportText(_:))
        case .clearScreen: return #selector(ViewController.clearScreen(_:))
        case .clearHistory: return #selector(ViewController.clearHistory(_:))
        case .resetTerminal: return #selector(ViewController.resetTerminal(_:))
        case .settings: return #selector(AppDelegate.showSettings(_:))
        case .commandPalette: return #selector(AppDelegate.showCommandPalette(_:))
        }
    }

    /// The shortcut a fresh install has. `nil` means the command is reachable
    /// from a menu and the palette but carries no key until the user gives it
    /// one — which is the right default for anything that would otherwise
    /// shadow a key the child process wants.
    var defaultShortcut: Shortcut? {
        switch self {
        case .newWindow: return Shortcut("n", .command)
        case .newTab: return Shortcut("t", .command)
        case .close: return Shortcut("w", .command)
        case .splitRight: return Shortcut("d", .command)
        case .splitDown: return Shortcut("d", [.command, .shift])
        case .focusLeft: return Shortcut(Shortcut.parse("left")!.key, [.command, .option])
        case .focusRight: return Shortcut(Shortcut.parse("right")!.key, [.command, .option])
        case .focusUp: return Shortcut(Shortcut.parse("up")!.key, [.command, .option])
        case .focusDown: return Shortcut(Shortcut.parse("down")!.key, [.command, .option])
        case .growPaneHorizontally:
            return Shortcut(Shortcut.parse("right")!.key, [.control, .command])
        case .shrinkPaneHorizontally:
            return Shortcut(Shortcut.parse("left")!.key, [.control, .command])
        case .growPaneVertically:
            return Shortcut(Shortcut.parse("down")!.key, [.control, .command])
        case .shrinkPaneVertically:
            return Shortcut(Shortcut.parse("up")!.key, [.control, .command])
        case .equalizePanes: return nil
        // ⇧⌘⏎ is tmux's `resize-pane -Z` habit written the Mac way, and no
        // menu item or system shortcut claims it.
        case .zoomPane: return Shortcut("\r", [.command, .shift])
        // ⇧⌘T is "bring back the tab I closed" in every browser; a pane is
        // the same gesture one level down.
        case .reopenClosedPane: return Shortcut("t", [.command, .shift])
        case .increaseFontSize: return Shortcut("=", .command)
        case .decreaseFontSize: return Shortcut("-", .command)
        case .resetFontSize: return Shortcut("0", .command)
        case .find: return Shortcut("f", .command)
        case .copy: return Shortcut("c", .command)
        case .paste: return Shortcut("v", .command)
        case .selectAll: return Shortcut("a", .command)
        case .scrollPageUp: return Shortcut(Shortcut.parse("pageup")!.key, .shift)
        case .scrollPageDown: return Shortcut(Shortcut.parse("pagedown")!.key, .shift)
        case .scrollToTop: return Shortcut(Shortcut.parse("home")!.key, .shift)
        case .scrollToBottom: return Shortcut(Shortcut.parse("end")!.key, .shift)
        case .previousCommand: return Shortcut(Shortcut.parse("up")!.key, .command)
        case .nextCommand: return Shortcut(Shortcut.parse("down")!.key, .command)
        // ⌘K is the key every Mac terminal puts on "clear what is on
        // screen". The other two ship unbound: both discard history, and a
        // key that throws away a build log by accident is not a default.
        // ⇧⌘↑/↓ sit next to ⌘↑/↓, which jump between all commands — the
        // shift narrows the same gesture to the ones that failed.
        case .previousFailedCommand:
            return Shortcut(Shortcut.parse("up")!.key, [.command, .shift])
        case .nextFailedCommand:
            return Shortcut(Shortcut.parse("down")!.key, [.command, .shift])
        case .copyLastCommandOutput: return nil
        case .snapshotRunningCommandOutput: return nil
        case .exportCommandOutput: return nil
        case .openFileReferenceInCommand: return nil
        case .revealWorkingDirectory: return nil
        case .copyWorkingDirectoryPath: return nil
        case .changeDirectoryToParent: return nil
        case .changeDirectoryToProjectRoot: return nil
        case .openParentDirectoryInNewPane: return nil
        case .openProjectRootInNewPane: return nil
        case .searchCommandHistory: return nil
        // ⇧⌘S, the save-as of an app that has no document to save.
        case .exportText: return Shortcut("s", [.command, .shift])
        case .clearScreen: return Shortcut("k", .command)
        case .clearHistory: return nil
        case .resetTerminal: return nil
        case .settings: return Shortcut(",", .command)
        case .commandPalette: return Shortcut("p", [.command, .shift])
        }
    }

    /// Which group the command palette lists it under.
    ///
    /// Thirty commands in one flat list is thirty things to read before
    /// finding the one you want; grouped, it is five short lists whose
    /// headings say which one to read. The grouping is the one the menu bar
    /// already uses, so the palette teaches where a command lives rather than
    /// replacing that knowledge.
    var category: CommandCategory {
        switch self {
        case .newWindow, .newTab, .close: return .window
        case .splitRight, .splitDown, .focusLeft, .focusRight, .focusUp, .focusDown,
            .growPaneHorizontally, .shrinkPaneHorizontally, .growPaneVertically,
            .shrinkPaneVertically, .equalizePanes, .zoomPane, .reopenClosedPane:
            return .panes
        case .increaseFontSize, .decreaseFontSize, .resetFontSize, .scrollPageUp,
            .scrollPageDown, .scrollToTop, .scrollToBottom, .previousCommand, .nextCommand,
            .previousFailedCommand, .nextFailedCommand, .copyLastCommandOutput,
            .snapshotRunningCommandOutput, .exportCommandOutput, .openFileReferenceInCommand,
            .revealWorkingDirectory, .copyWorkingDirectoryPath, .changeDirectoryToParent,
            .changeDirectoryToProjectRoot, .openParentDirectoryInNewPane,
            .openProjectRootInNewPane, .searchCommandHistory:
            return .view
        case .clearScreen, .clearHistory, .resetTerminal: return .terminal
        case .find, .copy, .paste, .selectAll, .exportText: return .edit
        case .settings, .commandPalette: return .app
        }
    }

    /// Where the command sits inside its group before any search or recency
    /// reordering: lower comes first. Ordered by how often a command is
    /// reached for, not alphabetically — an alphabetical list puts "Actual
    /// Size" above "Split Pane Right", which is not the order anybody wants.
    var paletteRank: Int {
        switch self {
        case .newTab: return 0
        case .newWindow: return 1
        case .close: return 2
        case .splitRight: return 0
        case .splitDown: return 1
        case .focusLeft: return 2
        case .focusRight: return 3
        case .focusUp: return 4
        case .focusDown: return 5
        case .zoomPane: return 6
        case .reopenClosedPane: return 7
        case .equalizePanes: return 8
        case .growPaneHorizontally: return 9
        case .shrinkPaneHorizontally: return 10
        case .growPaneVertically: return 11
        case .shrinkPaneVertically: return 12
        case .increaseFontSize: return 0
        case .decreaseFontSize: return 1
        case .resetFontSize: return 2
        case .scrollPageUp: return 3
        case .scrollPageDown: return 4
        case .scrollToTop: return 5
        case .scrollToBottom: return 6
        case .previousCommand: return 7
        case .nextCommand: return 8
        case .previousFailedCommand: return 9
        case .nextFailedCommand: return 10
        case .copyLastCommandOutput: return 11
        case .snapshotRunningCommandOutput: return 12
        case .exportCommandOutput: return 13
        case .openFileReferenceInCommand: return 14
        case .revealWorkingDirectory: return 15
        case .copyWorkingDirectoryPath: return 16
        case .changeDirectoryToParent: return 17
        case .changeDirectoryToProjectRoot: return 18
        case .openParentDirectoryInNewPane: return 19
        case .openProjectRootInNewPane: return 20
        case .searchCommandHistory: return 21
        case .copy: return 0
        case .paste: return 1
        case .selectAll: return 2
        case .find: return 3
        case .exportText: return 4
        case .clearScreen: return 0
        case .clearHistory: return 1
        case .resetTerminal: return 2
        case .settings: return 0
        case .commandPalette: return 1
        }
    }

    /// The config-file key this command's binding is written under.
    var configurationKey: String { "bind.\(rawValue)" }

    /// The menu item tag that tells this command apart from others sharing
    /// its action. Only the Find family needs one: five storyboard items send
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
    /// paste, the search bar, the scrollback jumps — used to compare against
    /// a literal instead, which made every one of them a second, invisible
    /// binding: rebinding the command left the literal working, and unbinding
    /// it did not stop the literal at all (U08). They ask this instead.
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
