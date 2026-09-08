import AppKit
import Testing

@testable import Corta

/// U08, U13 — the ordering claim the ghost-binding fix rests on, tested
/// rather than argued.
///
/// The argument was: AppKit dispatches a bound keystroke through its **menu
/// item** before `keyDown` ever runs, so a literal in `keyDown` fires only
/// when the menu has stopped claiming the key — which is exactly when the
/// user has rebound or unbound the command. That is AppKit behaviour, and the
/// previous record could only assert it by reasoning, because synthesising a
/// key event into another process needs Accessibility permission this session
/// cannot grant itself.
///
/// It does not need another process. `NSMenu.performKeyEquivalent(with:)` is
/// the same call `NSApplication.sendEvent` makes, and the real menu bar is
/// available in the test host — so the claim can be exercised directly on the
/// real menu, with real bindings, from here.
@MainActor
struct KeyEquivalentDispatchTests {
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

    /// Every command with a binding is claimed by a menu item carrying
    /// exactly that keystroke — which is what puts the menu, not `keyDown`,
    /// first for all of them.
    @Test func everyBoundCommandIsClaimedByAMenuItem() throws {
        let menu = try #require(NSApp.mainMenu)
        let bindings = ConfigurationStore.shared.configuration.keybindings
        var unclaimed: [String] = []
        for command in TerminalCommand.allCases {
            guard let shortcut = bindings[command] else { continue }
            let event = Self.eventFor(shortcut)
            guard Self.menuItem(claiming: event, in: menu) != nil else {
                unclaimed.append(command.rawValue)
                continue
            }
        }
        #expect(
            unclaimed.isEmpty,
            "no menu item claims the keystroke for: \(unclaimed.joined(separator: ", "))")
    }

    /// The three keystrokes U08 was about, each claimed by the menu item for
    /// the command that owns it — not by the command the literal used to run.
    @Test func theGhostBindingKeystrokesBelongToTheirOwners() throws {
        let menu = try #require(NSApp.mainMenu)
        let bindings = ConfigurationStore.shared.configuration.keybindings

        let paste = try #require(bindings[.paste])
        let pasteItem = try #require(Self.menuItem(claiming: Self.eventFor(paste), in: menu))
        #expect(pasteItem.action == TerminalCommand.paste.action)

        // ⌘↑ is Previous Command's, not the scrollback jump the literal ran.
        let previous = try #require(bindings[.previousCommand])
        let previousItem = try #require(Self.menuItem(claiming: Self.eventFor(previous), in: menu))
        #expect(previousItem.action == TerminalCommand.previousCommand.action)

        let find = try #require(bindings[.find])
        let findItem = try #require(Self.menuItem(claiming: Self.eventFor(find), in: menu))
        #expect(findItem.action == TerminalCommand.find.action)
    }

    /// U13 — Zoom Pane's key reaches the split controller's action, so the
    /// gesture is real and not only the menu row.
    @Test func zoomPaneIsReachableByItsKey() throws {
        let menu = try #require(NSApp.mainMenu)
        let shortcut = try #require(
            ConfigurationStore.shared.configuration.keybindings[.zoomPane])
        let item = try #require(Self.menuItem(claiming: Self.eventFor(shortcut), in: menu))
        #expect(item.action == #selector(SplitViewController.toggleZoomPane(_:)))
    }

    /// And the other half of the ordering claim: a keystroke no menu item
    /// carries is one `keyDown` will see. `equalize-panes` ships unbound, so
    /// nothing in the bar claims anything for it.
    @Test func anUnboundCommandLeavesNoMenuClaim() throws {
        let menu = try #require(NSApp.mainMenu)
        #expect(ConfigurationStore.shared.configuration.keybindings[.equalizePanes] == nil)
        let items = Self.items(in: menu).filter {
            $0.action == TerminalCommand.equalizePanes.action
        }
        #expect(!items.isEmpty, "the command should still have a menu row")
        #expect(items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    /// The event a shortcut would arrive as.
    private static func eventFor(_ shortcut: Shortcut) -> NSEvent {
        let key = shortcut.key
        let isFunctionKey = key.unicodeScalars.first.map { $0.value >= 0xF700 } ?? false
        var modifiers = shortcut.modifiers
        if isFunctionKey { modifiers.formUnion([.function, .numericPad]) }
        return event(key, ignoring: key, modifiers: modifiers)
    }

    /// The first menu item, in menu-bar traversal order, whose key equivalent
    /// matches — the same order AppKit resolves in.
    private static func menuItem(claiming event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = menuItem(claiming: event, in: submenu) { return found }
                continue
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            var mask = item.keyEquivalentModifierMask
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard event.modifierFlags.intersection(relevant) == mask.intersection(relevant),
                item.keyEquivalent.lowercased()
                    == event.charactersIgnoringModifiers?.lowercased()
            else { continue }
            return item
        }
        return nil
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            item.submenu.map { items(in: $0) } ?? [item]
        }
    }
}
