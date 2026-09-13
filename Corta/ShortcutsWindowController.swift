import AppKit
import SwiftUI

/// Help > Keyboard Shortcuts (⌘/).
///
/// **Why this exists.** Splitting a pane, resizing one, jumping between
/// commands, switching theme, scrolling the history: all of it was reachable
/// only by already knowing which menu it was under, or by opening the command
/// palette, which is itself the most hidden thing in the app. A terminal is
/// exactly the sort of application whose users will learn a shortcut list on
/// sight and never open a menu again — but only if there is a list.
///
/// A thin AppKit shell hosting `ShortcutsView` (SwiftUI), which owns the row
/// data and layout; see that type's doc comment for what and why.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("shortcuts.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ShortcutsView())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
