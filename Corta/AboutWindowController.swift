import AppKit
import SwiftUI

/// The About window.
///
/// It replaces `orderFrontStandardAboutPanel:`, which the storyboard wired up
/// and which showed the icon, the name, a version and then nothing: the panel
/// fills itself from `Info.plist`, `NSHumanReadableCopyright` was an empty
/// string, and there was no `Credits.rtf` to give it a body. The result was a
/// mostly empty box that answered none of the questions an About window is
/// opened to answer — what is this, which version am I running, where does it
/// live, what is it licensed under.
///
/// A thin AppKit shell hosting `AboutView` (SwiftUI), which owns every string
/// and layout decision; see that type's doc comment for what and why.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L10n.text("about.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: AboutView())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
