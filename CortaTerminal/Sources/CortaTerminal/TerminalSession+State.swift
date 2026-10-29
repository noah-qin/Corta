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
    /// Install before `start()`, so no startup bytes can beat the expectation.
    public func expectRemoteTmux(token: UUID) {
        state.withLock { $0.terminal.expectRemoteTmux(token: token) }
    }

    public var remoteTmuxReport: RemoteTmux.Report? { state.withLock { $0.terminal.remoteTmuxReport } }

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

    /// Every colour a frame resolves cells with, under one lock per frame.
    public var frameColors: FrameColors {
        registerStateWaiter {
            state.withLock {
                FrameColors(
                    indexedPalette: $0.terminal.indexedPalette, dynamicColors: $0.terminal.dynamicColors,
                    selectionBackground: $0.terminal.selectionBackground,
                    selectionForeground: $0.terminal.selectionForeground)
            }
        }
    }
    public func updateTheme(colors: DynamicColors, isDark: Bool) {
        registerStateWaiter {
            // Enqueue under the state lock: a later query cannot overtake a change report.
            state.withLock { current in
                let report = current.terminal.updateTheme(colors: colors, isDark: isDark)
                if !report.isEmpty { _ = enqueueWrite([report]) }
            }
        }
    }

    public var indexedPalette: IndexedPalette {
        get { registerStateWaiter { state.withLock { $0.terminal.indexedPalette } } }
        set { registerStateWaiter { state.withLock { $0.terminal.indexedPalette = newValue } } }
    }

    /// Under one lock: a get-then-set would race the reader's OSC 4 writes and
    /// could drop an override.
    public func updateIndexedPaletteDefaults(
        to newDefaults: [RGB]
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

    public var pointerShape: String? {
        registerStateWaiter { state.withLock { $0.terminal.pointerShape } }
    }
    public func updateBackingScale(_ scale: Double) {
        guard scale.isFinite, scale > 0, scale <= 8 else { return }
        registerStateWaiter { state.withLock { $0.terminal.grid.backingScale = scale } }
    }
    public var programStatuses: [String: ProgramStatus] {
        registerStateWaiter { state.withLock { $0.terminal.programStatuses } }
    }
    public var programProgress: ProgramProgress? {
        registerStateWaiter { state.withLock { $0.terminal.programProgress } }
    }
    /// One lock for a pane's whole agent-state read; drains its edges.
    public func takeProgramSignals() -> ProgramSignalSnapshot {
        registerStateWaiter { state.withLock { $0.terminal.takeProgramSignals() } }
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

    public var localConversation: LocalConversation? { pty.localConversation }

    public var foregroundProcessName: String? { pty.foregroundProcessName }

    /// Shell included, for a title bar.
    public var activeProcessName: String? { pty.activeProcessName }

    /// OSC 7 first (the shell's own answer); else the kernel's for the
    /// foreground group, since stock macOS zsh sends OSC 7 only to Terminal.app.
    public var currentDirectory: String? {
        workingDirectory ?? pty.currentWorkingDirectory
    }

    /// One flag, without copying the grid the way `snapshot()` would.
    public var isAlternateScreenActive: Bool {
        registerStateWaiter { state.withLock { $0.terminal.grid.isAlternateScreenActive } }
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

    public var historySuggestion: HistorySuggestion? {
        registerStateWaiter { state.withLock { $0.terminal.historySuggestion } }
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

    public func takeClipboardCopyRequest() -> ClipboardCopyRequest? {
        registerStateWaiter { state.withLock { $0.terminal.takeClipboardCopyRequest() } }
    }
}
