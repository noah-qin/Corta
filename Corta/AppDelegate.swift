//
//  AppDelegate.swift
//  Corta
//
//  Created by Noah on 9/1/26.
//

import Cocoa
import CortaTerminal

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong references to every open terminal window's controller —
    /// nothing else retains a window controller, and a deallocated
    /// controller takes its window (and its session) down with it.
    private var windowControllers: [NSWindowController] = []

    /// File > New (⌘N), wired in the storyboard to First Responder. Each
    /// window is its own `SplitViewController` composing one or more
    /// panes — each pane a `ViewController` with its own
    /// `TerminalSession` — so a new window is composition, not new
    /// mechanism (`DESIGN.md` §2.4).
    @objc func newDocument(_ sender: Any?) {
        guard let controller = instantiateWindowController() else { return }
        // Offset from the window it was opened from. Placed at the same
        // origin the new window is invisible behind the old one, and ⌘N
        // looks like it did nothing.
        if let previous = NSApp.keyWindow, let window = controller.window {
            window.setFrameTopLeftPoint(
                NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    /// File > New Tab (⌘T, M4.7): native window tabbing. The new session is
    /// a full window of its own, added to the key window's tab group — so a
    /// tab can always be dragged out into a standalone window again, and
    /// ⌘N keeps meaning "new window".
    @objc func newTab(_ sender: Any?) {
        guard let controller = instantiateWindowController(),
            let window = controller.window
        else { return }
        window.tabbingMode = .automatic
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            // Join at the group's size: being born at the default size and
            // then resized by the tab group reads as a flash.
            window.setFrame(keyWindow.frame, display: false)
            keyWindow.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    /// The tab bar's "+" button sends this through the responder chain;
    /// with no implementor in the chain AppKit does not show the button at
    /// all, so this is also what makes the button appear.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    /// One storyboard window controller, tracked so it lives as long as its
    /// window does.
    private func instantiateWindowController() -> NSWindowController? {
        guard let controller = NSStoryboard(name: "Main", bundle: nil)
            .instantiateInitialController() as? NSWindowController
        else { return nil }
        track(controller)
        return controller
    }

    /// Retains `controller` until its window closes, so the array does not
    /// grow without bound and no open window loses its controller.
    private func track(_ controller: NSWindowController) {
        guard !windowControllers.contains(controller) else { return }
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: controller.window)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The storyboard's initial window controller shows the first window;
        // nothing retains it either, so track it like the ⌘N windows.
        for window in NSApp.windows {
            if let controller = window.windowController {
                track(controller)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}
