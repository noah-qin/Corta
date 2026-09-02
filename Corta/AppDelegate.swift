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
    /// window is its own `ViewController` with its own `TerminalSession` —
    /// the per-session architecture (`DESIGN.md` §2.4) makes a new window
    /// composition, not new mechanism.
    @objc func newDocument(_ sender: Any?) {
        guard let controller = NSStoryboard(name: "Main", bundle: nil)
            .instantiateInitialController() as? NSWindowController
        else { return }
        track(controller)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
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
