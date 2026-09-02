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
