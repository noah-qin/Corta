import AppKit
import SwiftUI

/// M7.12 — the command palette.
///
/// Corta reached about thirty commands spread across five menus, a context
/// menu and a settings page, and the only way to find one was to already
/// know which menu it was under. A palette is the cheap fix: type part of a
/// name, press Return.
///
/// `CommandPaletteModel` owns the filtering and selection; `CommandPaletteView`
/// (SwiftUI) owns the layout. This class only builds the floating panel — the
/// glass background is `NSGlassEffectView`, which SwiftUI has no equivalent
/// for on this deployment target, so the panel's chrome stays AppKit around a
/// hosted SwiftUI content view, the same shape every other converted window
/// in this app uses in reverse (an AppKit shell around SwiftUI content,
/// rather than SwiftUI content that happens to need one AppKit material).
///
/// Dispatch goes through `NSApp.sendAction(_:to:from:)` with a `nil` target,
/// which is the responder chain — exactly what a menu item does. That is
/// what makes "Split Pane Right" from the palette land on the right window's
/// split controller without the palette knowing any of them exist. The
/// panel is closed *before* the action is sent, because while it is key the
/// chain starts at the palette and every terminal command would find no
/// handler.
@MainActor
final class CommandPaletteController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteController()

    let model = CommandPaletteModel()
    /// The window the palette was opened over. Commands act on the key
    /// window, and the palette itself becomes key while it is up.
    private weak var invokingWindow: NSWindow?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = Self.buildContentView(model: model)
        model.onRun = { [weak self] command in
            self?.close()
            // After the palette is gone and the terminal window is key
            // again, so the responder chain is the one the command expects.
            DispatchQueue.main.async {
                NSApp.sendAction(command.action, to: nil, from: nil)
            }
        }
        model.onDismiss = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presenting

    @objc func show(_ sender: Any?) {
        guard let window else { return }
        invokingWindow = NSApp.keyWindow
        model.reset()
        if let host = invokingWindow {
            // Centred over the window it was invoked from, a third of the way
            // down — where a palette is looked for, and clear of the prompt.
            let frame = window.frame
            window.setFrameOrigin(
                NSPoint(
                    x: host.frame.midX - frame.width / 2,
                    y: host.frame.maxY - frame.height - host.frame.height / 6))
        } else {
            window.center()
        }
        showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    override func close() {
        window?.orderOut(nil)
        invokingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away dismisses, like every other palette.
        close()
    }

    // MARK: - Layout

    /// M9: a floating control over content is exactly where Liquid Glass
    /// belongs (`ViewController.swift`'s rationale for the search bar,
    /// `:383-390` — the terminal canvas is content and stays opaque; the
    /// palette is chrome, like the search bar). One surface, so no
    /// `NSGlassEffectContainerView` merge to set up — that exists for
    /// *neighbouring* glass elements, and the palette has none.
    private static func buildContentView(model: CommandPaletteModel) -> NSView {
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let content = NSGlassEffectView()
        content.style = .regular
        // Reduce Transparency means background content must not show
        // through, so the glass gets an opaque tint rather than a lowered
        // alpha — same as the search bar — and the panel then needs a
        // drawn border, because the material edge that separated it from
        // the desktop is gone with it.
        if SystemAccessibility.reduceTransparency {
            content.tintColor = .windowBackgroundColor
        }
        if SystemAccessibility.increaseContrast || SystemAccessibility.reduceTransparency {
            content.wantsLayer = true
            let border = SystemAccessibility.panelBorder
            content.layer?.borderColor = border.color.cgColor
            content.layer?.borderWidth = border.width
        }
        let wrapper = NSView()
        wrapper.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: wrapper.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        content.contentView = wrapper
        // The panel's own contentRect is fixed at construction (`init`,
        // `NSRect(x: 0, y: 0, width: 520, height: 360)`), unlike the search
        // bar's — which waits on live layout — so the radius is knowable
        // immediately. Matches the window-corner radius used elsewhere
        // (`TerminalView.swift`'s `metalLayer.cornerRadius = 10`) rather
        // than the search bar's full pill: a whole panel reads as a window,
        // not a control.
        content.cornerRadius = 10
        return content
    }
}
