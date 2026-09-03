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
        let name = Self.namedKeys.first { $0.key == key }?.name ?? key
        return glyphs + name.uppercased()
    }

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
    case settings
    case commandPalette = "command-palette"

    /// What the menus and the palette call it.
    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .close: return "Close"
        case .splitRight: return "Split Pane Right"
        case .splitDown: return "Split Pane Down"
        case .focusLeft: return "Move Focus Left"
        case .focusRight: return "Move Focus Right"
        case .focusUp: return "Move Focus Up"
        case .focusDown: return "Move Focus Down"
        case .growPaneHorizontally: return "Grow Pane Horizontally"
        case .shrinkPaneHorizontally: return "Shrink Pane Horizontally"
        case .growPaneVertically: return "Grow Pane Vertically"
        case .shrinkPaneVertically: return "Shrink Pane Vertically"
        case .equalizePanes: return "Equalize Panes"
        case .increaseFontSize: return "Bigger"
        case .decreaseFontSize: return "Smaller"
        case .resetFontSize: return "Actual Size"
        case .find: return "Find…"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .scrollPageUp: return "Scroll Page Up"
        case .scrollPageDown: return "Scroll Page Down"
        case .scrollToTop: return "Scroll to Top"
        case .scrollToBottom: return "Scroll to Bottom"
        case .previousCommand: return "Previous Command"
        case .nextCommand: return "Next Command"
        case .settings: return "Settings…"
        case .commandPalette: return "Command Palette…"
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
        case .settings: return Shortcut(",", .command)
        case .commandPalette: return Shortcut("p", [.command, .shift])
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

    var isCustomised: Bool { !overrides.isEmpty }

    /// The overrides, in `TerminalCommand.allCases` order, for serialisation.
    var overriddenCommands: [(TerminalCommand, Shortcut?)] {
        TerminalCommand.allCases.compactMap { command in
            overrides[command].map { (command, $0) }
        }
    }
}
