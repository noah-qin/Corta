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

import Darwin
import Foundation
import Synchronization

/// What the terminal reports about itself: modes, colours, titles, directories and command records. Any thread.
extension TerminalSession {
    /// Without a full `snapshot()`; read on every scroll and output batch.
    public var scrollbackTotalPushed: Int {
        registerStateWaiter { state.withLock { $0.terminal.grid.scrollback.totalPushed } }
    }

    public var isBracketedPasteEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isBracketedPasteEnabled } }
    }

    /// `.off` unless SGR encoding is on; both read under one lock.
    public var sgrMouseTrackingMode: MouseTrackingMode {
        registerStateWaiter {
            state.withLock {
                $0.terminal.isSgrMouseEncodingEnabled ? $0.terminal.mouseTrackingMode : .off
            }
        }
    }

    /// Can go false without the child's DECRST (timeout, exit).
    public var isSynchronizedOutputEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isSynchronizedOutputEnabled } }
    }

    public var isFocusReportingEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isFocusReportingEnabled } }
    }

    public var isNewLineModeEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isNewLineModeEnabled } }
    }

    /// `Terminal.wheelSendsArrowKeys`, read per wheel event.
    public var wheelSendsArrowKeys: Bool {
        registerStateWaiter { state.withLock { $0.terminal.wheelSendsArrowKeys } }
    }

    public var applicationCursorKeysEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.applicationCursorKeysEnabled } }
    }

    public var applicationKeypadEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.applicationKeypadEnabled } }
    }

    public var dynamicColors: DynamicColors {
        get { registerStateWaiter { state.withLock { $0.terminal.dynamicColors } } }
        set { registerStateWaiter { state.withLock { $0.terminal.dynamicColors = newValue } } }
    }

    public var indexedPalette: IndexedPalette {
        get { registerStateWaiter { state.withLock { $0.terminal.indexedPalette } } }
        set { registerStateWaiter { state.withLock { $0.terminal.indexedPalette = newValue } } }
    }

    /// Under one lock: a get-then-set would race the reader's OSC 4 writes and
    /// could drop an override.
    public func updateIndexedPaletteDefaults(
        to newDefaults: [(red: UInt8, green: UInt8, blue: UInt8)]
    ) {
        registerStateWaiter { state.withLock { $0.terminal.indexedPalette.updateDefaults(to: newDefaults) } }
    }

    /// `ambiguous-width`, for output written from now on.
    public var ambiguousWidthIsWide: Bool {
        get { registerStateWaiter { state.withLock { $0.terminal.grid.ambiguousIsWide } } }
        set { registerStateWaiter { state.withLock { $0.terminal.grid.ambiguousIsWide = newValue } } }
    }

    public var keyboardEnhancements: KeyboardEnhancementFlags {
        registerStateWaiter { state.withLock { $0.terminal.keyboardEnhancements } }
    }

    public func takeBell() -> Bool {
        registerStateWaiter { state.withLock { $0.terminal.takeBell() } }
    }

    public var windowTitle: String? {
        registerStateWaiter { state.withLock { $0.terminal.windowTitle } }
    }

    /// Always local, safe to spawn or restore from: the shell's OSC 7 report,
    /// once the kernel agrees a local process is there
    /// (`PTY.confirmedWorkingDirectory`); `nil` until a local report arrives.
    public var workingDirectory: String? {
        guard let reported = registerStateWaiter({ state.withLock { $0.terminal.workingDirectory } })
        else { return nil }
        return pty.confirmedWorkingDirectory(reported)
    }

    /// Informational only; never for spawning.
    public var remoteContext: RemoteContext? {
        registerStateWaiter { state.withLock { $0.terminal.remoteContext } }
    }

    /// A command other than the shell is running — what a close confirmation
    /// asks (`PTY.hasForegroundJob`).
    public var hasForegroundJob: Bool { pty.hasForegroundJob }

    public var foregroundProcessName: String? { pty.foregroundProcessName }

    /// Shell included, for a title bar.
    public var activeProcessName: String? { pty.activeProcessName }

    /// OSC 7 first (the shell's own answer); else the kernel's for the
    /// foreground group, since stock macOS zsh sends OSC 7 only to Terminal.app.
    public var currentDirectory: String? {
        workingDirectory ?? pty.currentWorkingDirectory
    }

    public var isCommandRunning: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isCommandRunning } }
    }

    public var hasShellIntegration: Bool {
        registerStateWaiter { state.withLock { $0.terminal.hasShellIntegration } }
    }

    public var promptEndPosition: (row: Int, column: Int)? {
        registerStateWaiter { state.withLock { $0.terminal.promptEndPosition } }
    }

    public var directoryCompletion: DirectoryCompletion? {
        registerStateWaiter { state.withLock { $0.terminal.directoryCompletion } }
    }

    public var commandRecords: CommandRecordStore {
        registerStateWaiter { state.withLock { $0.terminal.commandRecords } }
    }

    public func clearCommandRecords() {
        registerStateWaiter { state.withLock { $0.terminal.clearCommandRecords() } }
    }

    public func takeFinishedCommand() -> Int? {
        registerStateWaiter { state.withLock { $0.terminal.takeFinishedCommand() } }
    }

    /// OSC 52; the app decides whether it reaches the pasteboard.
    public func takeClipboardCopy() -> String? {
        registerStateWaiter { state.withLock { $0.terminal.takeClipboardCopy() } }
    }
}
