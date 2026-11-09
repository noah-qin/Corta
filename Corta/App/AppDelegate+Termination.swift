// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UserNotifications

/// Quitting: the question when something runs, and the last writes.
extension AppDelegate {
    /// Confirms ⌘Q with something running; quitting bypasses
    /// `windowShouldClose`. A sheet on the key terminal window (or the first
    /// visible one), answered later; app-modal, answered now, when none is
    /// visible.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // On the way out AppKit resolves what this app still promises on any
        // pasteboard, and a dragged SFTP row's file is a promise nobody can keep
        // by then: that wait never ended, and the app never quit. Dropping the
        // promise costs nothing if the quit is cancelled: its drag is over.
        NSPasteboard(name: .drag).clearContents()
        let running = windowControllers.flatMap { $0.window?.terminalSplits ?? [] }
            .flatMap(\.panes).filter(\.hasSessionRequiringCloseConfirmation)
        guard let split = windowControllers.first?.window?.terminalSplit,
            split.needsCloseConfirmation(for: running)
        else { return .terminateNow }
        // Already asking: that sheet answers this quit too.
        guard !isAskingToTerminate else { return .terminateCancel }
        // A window is already asking whether to close what runs in it: a
        // second, app-wide question on top would ask the same thing twice.
        // Its sheet comes forward and answers first.
        if let asking = Self.windowAskingToClose(among: windowControllers.compactMap(\.window)) {
            NSApp.activate()
            asking.makeKeyAndOrderFront(nil)
            asking.attachedSheet?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        // Only terminal windows with room to present a confirmation sheet.
        let windows = windowControllers.compactMap { controller -> NSWindow? in
            guard let terminal = controller as? TerminalWindowController
            else { return nil }
            return terminal.window
        }.filter { NSAlert.canPresentSheet(on: $0) }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
            let presenter = window.terminalSplit
        else {
            let alert = split.closeAlert(for: running, scope: L10n.text("close.scope.app"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        isAskingToTerminate = true
        presenter.confirmClose(of: running, scope: L10n.text("close.scope.app"), in: window) { [weak self] in
            self?.isAskingToTerminate = false
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        stallTimer?.invalidate()
        stallTimer = nil
        isTerminating = true
        let (writes, deadline) = beginLastWrites()
        ZshBootstrap.removeGeneratedFiles()
        // The askpass socket and its directory.
        SSHAskpassBroker.shared.stop()
        // The secure-input count must reach zero before exit.
        SecureInput.shared.disengage()
        // Not every quit path reaches `windowWillClose`; tear down explicitly
        // rather than leave children to SIGHUP.
        for controller in windowControllers {
            for split in controller.window?.terminalSplits ?? [] { split.teardown() }
        }
        // Not left to the panes' background removals: the process is ending.
        FileDropStorage.removeThisRun(into: writes, deadline: deadline)
        _ = writes.wait(timeout: deadline)
    }
}
