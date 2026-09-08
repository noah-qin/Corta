import AppKit
import Testing

@testable import Corta

/// Menu key equivalents match in menu order: the first item claiming a
/// keystroke wins and every later item is a dead key. The stock storyboard's
/// Format ▸ Font ▸ Smaller claimed ⌘- ahead of View ▸ Smaller and sent it to
/// the font panel's `modifyFont:`, which a terminal does not implement — so
/// ⌘- did nothing (Track D's View menu item was correct all along). The
/// rich-text Format menu was removed wholesale; these tests pin the
/// invariant behind that decision.
@MainActor
struct MenuShortcutTests {
    /// Every menu item with a key equivalent, as (item, "Menu > Item" path).
    private static func shortcuts(
        in menu: NSMenu, path: String = ""
    ) -> [(item: NSMenuItem, path: String)] {
        var result: [(NSMenuItem, String)] = []
        for item in menu.items {
            let title = path.isEmpty ? item.title : "\(path) > \(item.title)"
            if !item.keyEquivalent.isEmpty {
                result.append((item, title))
            }
            if let submenu = item.submenu {
                result.append(contentsOf: shortcuts(in: submenu, path: title))
            }
        }
        return result
    }

    /// A normalized keystroke: lowercase key plus effective modifiers (an
    /// uppercase keyEquivalent implies ⇧).
    private static func keystroke(of item: NSMenuItem) -> String {
        var mask = item.keyEquivalentModifierMask
        if item.keyEquivalent != item.keyEquivalent.lowercased() {
            mask.insert(.shift)
        }
        let relevant = mask.intersection([.command, .option, .control, .shift])
        return "\(item.keyEquivalent.lowercased()) \(relevant.rawValue)"
    }

    @Test func noKeystrokeIsClaimedByTwoMenuItems() throws {
        let menu = try #require(NSApp.mainMenu)
        var seen: [String: String] = [:]
        var duplicates: [String] = []
        for (item, path) in Self.shortcuts(in: menu) {
            let key = Self.keystroke(of: item)
            if let existing = seen[key] {
                duplicates.append("\(existing) vs \(path)")
            } else {
                seen[key] = path
            }
        }
        #expect(duplicates.isEmpty, "duplicate key equivalents: \(duplicates.joined(separator: ", "))")
    }

    /// U08 — one source of truth. The menu bar, the command palette and
    /// Help ▸ Keyboard Shortcuts must all show the key that actually runs the
    /// command; the palette and the sheet both read
    /// `keybindings[command]?.displayText`, and this pins the third consumer,
    /// the one AppKit dispatches from. A menu item whose key equivalent
    /// drifted from the table is a shortcut the sheet documents and the app
    /// does not have.
    @Test func everyMenuKeyEquivalentComesFromTheBindings() throws {
        let menu = try #require(NSApp.mainMenu)
        let bindings = ConfigurationStore.shared.configuration.keybindings
        for command in TerminalCommand.allCases {
            let shortcut = bindings[command]
            for (item, path) in Self.items(for: command, in: menu) {
                #expect(
                    item.keyEquivalent == (shortcut?.menuKeyEquivalent ?? ""),
                    "\(path): key equivalent does not match bind.\(command.rawValue)")
                #expect(
                    item.keyEquivalentModifierMask == (shortcut?.menuModifierMask ?? []),
                    "\(path): modifier mask does not match bind.\(command.rawValue)")
            }
        }
    }

    /// A command with no binding must be keyless everywhere: no menu key
    /// equivalent, and an em dash in the sheet rather than a stale glyph.
    /// `equalize-panes` ships unbound, so the invariant has a live case.
    @Test func anUnboundCommandIsKeylessEverywhere() throws {
        let menu = try #require(NSApp.mainMenu)
        let bindings = ConfigurationStore.shared.configuration.keybindings
        let unbound = TerminalCommand.allCases.filter { bindings[$0] == nil }
        #expect(unbound.contains(.equalizePanes))
        for command in unbound {
            for (item, path) in Self.items(for: command, in: menu) {
                #expect(item.keyEquivalent.isEmpty, "\(path) still carries a key equivalent")
            }
            #expect(bindings[command]?.displayText == nil)
        }
    }

    /// Nothing rejects two `bind.` lines naming one keystroke, so the
    /// resolution has to be defined rather than arbitrary: the first command
    /// in `TerminalCommand.allCases` order wins where Corta decides, and the
    /// sheet prints the key twice, which is how the user sees the collision.
    @Test func collidingBindingsResolveInADeclarationOrder() throws {
        let (configuration, unknown) = Configuration.parse("bind.split-down = cmd+d")
        #expect(unknown.isEmpty)
        let bindings = configuration.keybindings
        let commandD = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2)!
        #expect(bindings.commands(boundTo: commandD) == [.splitRight, .splitDown])
    }

    /// Every menu item sending `command`'s action, with its menu path. Items
    /// distinguished only by tag (the five Find items) are filtered the same
    /// way `AppDelegate.applyKeybindings` filters them.
    private static func items(
        for command: TerminalCommand, in menu: NSMenu, path: String = ""
    ) -> [(item: NSMenuItem, path: String)] {
        var result: [(NSMenuItem, String)] = []
        for item in menu.items {
            let title = path.isEmpty ? item.title : "\(path) > \(item.title)"
            if item.action == command.action, command.menuTag.map({ $0 == item.tag }) ?? true {
                result.append((item, title))
            }
            if let submenu = item.submenu {
                result.append(contentsOf: items(for: command, in: submenu, path: title))
            }
        }
        return result
    }

    @Test func commandMinusIsTheViewMenusSmaller() throws {
        let menu = try #require(NSApp.mainMenu)
        let claims = Self.shortcuts(in: menu).filter {
            $0.item.keyEquivalent == "-" && $0.item.keyEquivalentModifierMask == .command
        }
        #expect(claims.count == 1)
        #expect(claims.first?.path == "View > Smaller")
        #expect(claims.first?.item.action == #selector(ViewController.decreaseFontSize(_:)))
    }
}
