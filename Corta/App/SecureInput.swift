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
import Carbon.HIToolbox

/// Secure Keyboard Entry, as in Terminal.app and iTerm2: while engaged no
/// event tap, keylogger or accessibility client sees keystrokes. It is
/// system-wide, silencing wanted tools too, hence a setting
/// (`SECURITY.md` §4).
///
/// **Balanced by construction.** `EnableSecureEventInput` is a counter;
/// an unmatched call leaves the machine in secure mode after quit. This
/// type is the only caller, holds one bit (`engaged`) computed from the
/// setting, app activation and a key terminal window on every change, so
/// the counter never exceeds one, and `disengage()` zeroes it at quit.
@MainActor
final class SecureInput {
    static let shared = SecureInput()

    /// Injectable, so tests never flip the machine's input mode.
    struct System {
        var enable: () -> Void
        var disable: () -> Void

        static let live = System(
            enable: { EnableSecureEventInput() },
            disable: { DisableSecureEventInput() })
    }

    private let system: System
    private var observers: [NSObjectProtocol] = []

    /// The three inputs, so one change recomputes against the others.
    private(set) var wanted = false
    private(set) var applicationIsActive = false
    private(set) var terminalWindowIsKey = false

    private(set) var engaged = false

    /// Posted when `engaged` changes, so the menu and titlebar show the
    /// actual state, not the setting.
    static let didChange = Notification.Name("SecureInput.didChange")

    init(system: System = .live) {
        self.system = system
    }

    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationIsActive = true; self?.reconcile() }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationIsActive = false; self?.reconcile() }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                let isTerminal = Self.isTerminalWindow(note.object)
                MainActor.assumeIsolated {
                    self?.terminalWindowIsKey = isTerminal
                    self?.reconcile()
                }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                // Only a terminal window resigning changes whether one is key.
                guard Self.isTerminalWindow(note.object) else { return }
                MainActor.assumeIsolated {
                    self?.terminalWindowIsKey = false
                    self?.reconcile()
                }
            },
            center.addObserver(
                forName: ConfigurationStore.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySetting() }
            },
        ]
        applicationIsActive = NSApp.isActive
        terminalWindowIsKey = Self.isTerminalWindow(NSApp.keyWindow)
        applySetting()
    }

    /// Settings, About and the SFTP browser don't hold prompt passwords.
    nonisolated private static func isTerminalWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        // Window notifications arrive on the main thread.
        return MainActor.assumeIsolated { window.windowController is TerminalWindowController }
    }

    private func applySetting() {
        update(wanted: ConfigurationStore.shared.configuration.secureKeyboardEntry)
    }

    /// The config file's setting; the menu writes the file, so both are one
    /// path.
    func update(wanted: Bool) {
        self.wanted = wanted
        reconcile()
    }

    /// Test seam.
    func update(applicationIsActive: Bool, terminalWindowIsKey: Bool) {
        self.applicationIsActive = applicationIsActive
        self.terminalWindowIsKey = terminalWindowIsKey
        reconcile()
    }

    private var shouldBeEngaged: Bool { wanted && applicationIsActive && terminalWindowIsKey }

    private func reconcile() {
        let target = shouldBeEngaged
        guard target != engaged else { return }
        if target { system.enable() } else { system.disable() }
        engaged = target
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Releases unconditionally, for `applicationWillTerminate`.
    func disengage() {
        guard engaged else { return }
        system.disable()
        engaged = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
