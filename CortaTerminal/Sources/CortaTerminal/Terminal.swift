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

/// A terminal: bytes in, grid out — the unit a golden test feeds and a
/// viewport renders (`DECISIONS.md` D07). Not isolated: `TerminalSession`
/// owns the child process and synchronizes access.
public struct Terminal: Sendable {
    private var parser = Parser()
    private var performer: Performer

    public init(
        rows: Int = 24,
        columns: Int = 80,
        scrollbackLimit: Int = Scrollback.defaultLimit,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity
    ) {
        self.performer = Performer(
            grid: Grid(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
        )
        self.performer.state.commandRecords = CommandRecordStore(capacity: commandHistoryLimit)
    }

    /// Independent of `reset()`, as clearing directory history is of clearing
    /// the scrollback.
    public mutating func clearCommandRecords() {
        performer.state.commandRecords = CommandRecordStore(
            capacity: performer.state.commandRecords.capacity)
    }

    public var grid: Grid {
        get { performer.grid }
        set { performer.grid = newValue }
    }

    /// Clear Screen: the grid's, and the waiting prompt follows the cursor to
    /// the top, where the next command is typed.
    public mutating func clearScreen() {
        performer.grid.clearScreen()
        performer.screenClearedByUser()
    }

    /// `RIS`, applied here rather than written to the child's input, which
    /// carries only what the user typed (`SECURITY.md` §6).
    public mutating func reset() {
        feed(Array("\u{1B}c".utf8))
    }

    /// A chunk may end mid-character or mid-sequence; all decoding state
    /// lives in the terminal.
    public mutating func feed(_ bytes: some Sequence<UInt8>) {
        parser.parse(bytes, performer: &performer)
    }

    /// Contiguous, so `Parser` can batch printable ASCII.
    public mutating func feed(_ bytes: [UInt8]) {
        parser.parse(bytes, performer: &performer)
    }

    /// Contiguous, and fed without a copy: the reader's lock slices.
    public mutating func feed(_ bytes: ArraySlice<UInt8>) {
        parser.parse(bytes, performer: &performer)
    }

    public var hasPendingOutput: Bool { !performer.state.outputBuffer.isEmpty }

    public var isBracketedPasteEnabled: Bool { performer.state.bracketedPasteEnabled }

    public var mouseTrackingMode: MouseTrackingMode { performer.state.mouseTrackingMode }

    public var isSgrMouseEncodingEnabled: Bool { performer.state.sgrMouseEncodingEnabled }

    public var isSynchronizedOutputEnabled: Bool { performer.state.synchronizedOutputEnabled }

    public var synchronizedOutputEpisode: Int { performer.state.synchronizedOutputEpisode }

    /// Ends `?2026` without the child's DECRST: a crashed or buggy child never
    /// sends it, and gating presents on it would freeze the pane.
    public mutating func endSynchronizedOutput() {
        performer.state.synchronizedOutputEnabled = false
    }

    public var isFocusReportingEnabled: Bool { performer.state.focusReportingEnabled }

    /// The wheel should send arrow keys (`?1007`): on the alternate screen,
    /// alternate scroll on, mouse reporting off.
    public var wheelSendsArrowKeys: Bool {
        performer.grid.isAlternateScreenActive && performer.state.alternateScrollEnabled
            && performer.state.mouseTrackingMode == .off
    }

    public var isNewLineModeEnabled: Bool { performer.state.newLineModeEnabled }

    public var applicationCursorKeysEnabled: Bool {
        performer.state.applicationCursorKeysEnabled
    }

    public var applicationKeypadEnabled: Bool {
        performer.state.applicationKeypadEnabled
    }

    /// Seeded by the app from its palette, so a query answers with what is
    /// drawn; read back to render what the child set.
    public var dynamicColors: DynamicColors {
        get { performer.state.dynamicColors }
        set { performer.state.dynamicColors = newValue }
    }

    public var indexedPalette: IndexedPalette {
        get { performer.state.indexedPalette }
        set { performer.state.indexedPalette = newValue }
    }

    public var specialColors: SpecialColors {
        get { performer.state.specialColors }
        set { performer.state.specialColors = newValue }
    }

    public var keyboardEnhancements: KeyboardEnhancementFlags {
        performer.state.keyboardProtocol.current
    }

    // The `take…` accessors drain: each event is reported once, not on every
    // frame after it.

    public mutating func takeBell() -> Bool {
        let requested = performer.state.bellRequested
        performer.state.bellRequested = false
        return requested
    }

    public var windowTitle: String? { performer.state.windowTitle }

    /// Local-or-nil by construction, so always safe for a local spawn.
    public var workingDirectory: String? { performer.state.workingDirectory }

    /// Informational only; nothing that spawns a process may read it.
    public var remoteContext: RemoteContext? { performer.state.remoteContext }

    /// `false` without shell integration too, which is why the app keeps its
    /// keystroke heuristic as a fallback.
    public var isCommandRunning: Bool { performer.state.isCommandRunning }

    /// Whether the shell has ever emitted an OSC 133 mark.
    public var hasShellIntegration: Bool { performer.state.promptRow != nil }

    /// `nil` unless `B` landed on the same row as this prompt's `A`.
    public var promptEndPosition: (row: Int, column: Int)? {
        guard let row = performer.state.promptRow, let column = performer.state.promptEndColumn
        else { return nil }
        return (row, column)
    }

    public var commandRecords: CommandRecordStore { performer.state.commandRecords }

    public mutating func takeFinishedCommand() -> Int? {
        let status = performer.state.finishedCommandExitStatus
        performer.state.finishedCommandExitStatus = nil
        return status
    }

    /// OSC 52 writes; the app decides whether to honour them.
    public mutating func takeClipboardCopy() -> String? {
        let text = performer.state.pendingClipboardCopy
        performer.state.pendingClipboardCopy = nil
        return text
    }

    /// Query responses; `TerminalSession` writes them to the PTY after every
    /// `feed`.
    public mutating func takeOutput() -> [UInt8] {
        let output = performer.state.outputBuffer
        performer.state.outputBuffer = []
        return output
    }

    public func dump(options: DumpOptions = .default) -> String {
        performer.grid.dump(options: options)
    }
}
