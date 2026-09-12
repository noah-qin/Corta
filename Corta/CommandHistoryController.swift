import AppKit
import SwiftUI

/// B08 — search command records by directory, project and exit status;
/// separate find/fill/run actions. `host` stays out of scope, the same
/// reason `CommandRecordStore.records(inDirectory:...)`'s own doc comment
/// gives: nothing carries one yet, and a real one waits for B13's SSH work.
///
/// B10 — this project's first SwiftUI surface: the window and its chrome
/// are still AppKit (an `NSWindowController` is still what `showWindow`/
/// window lifecycle need), but the content is `CommandHistoryView` hosted
/// through `NSHostingController`, and every piece of state it reads or
/// writes lives in `CommandHistoryModel` rather than in view objects this
/// controller would otherwise have to build and rebuild by hand.
///
/// A single shared window, re-targeted at whichever pane opened it —
/// `ShortcutsWindowController`'s pattern, not a fresh window per pane, since
/// only one can be meaningfully in front at a time and the history it shows
/// is only ever "this pane's".
@MainActor
final class CommandHistoryController: NSWindowController {
    static let shared = CommandHistoryController()

    let model = CommandHistoryModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("commandHistory.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: CommandHistoryView(model: model))
        model.onDismiss = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(for pane: ViewController) {
        model.pane = pane
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
