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

import Foundation

/// OSC 133 — shell integration: the shell states command boundaries instead
/// of Corta guessing them. `A` prompt start, `B` prompt end (typing begins),
/// `C` output begins, `D` finished (`;<status>`).
///
/// Only a bounded exit status is read from the payload (`SECURITY.md` §2.1);
/// `aid=`/`cl=` are ignored — unparsed is unexploitable.
extension Performer {
    mutating func shellIntegration(_ payload: ArraySlice<UInt8>) {
        // Not on the alternate screen: its rows vanish when the TUI exits.
        guard !grid.isAlternateScreenActive, let kind = payload.first else { return }
        switch kind {
        case 0x41:  // 'A' — prompt start
            let row = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            // Nothing ran at the last prompt — no `C`, no `D` — so this is that
            // prompt again: redrawn after an empty line, or fish 4's own mark
            // beside a hook's. A new record here was a phantom command.
            let nothingRan =
                state.promptRow != nil && !state.isCommandRunning && state.commandExitStatus == nil
            state.promptRow = row
            state.commandExitStatus = nil
            state.promptAwaitsRepaint = false
            state.sawPromptEnd = false
            // Until this prompt's own 'B', a `cd` must not read the last one's.
            state.promptEndColumn = nil
            grid.setMark(.prompt, atAbsoluteRow: row)
            if nothingRan {
                state.commandRecords.movePrompt(
                    to: row, workingDirectory: state.workingDirectory,
                    host: state.remoteContext?.host, at: Date())
            } else {
                state.commandRecords.begin(
                    promptRow: row, workingDirectory: state.workingDirectory,
                    host: state.remoteContext?.host, at: Date())
            }
        case 0x42:  // 'B' — command line starts
            // The prompt an erase wiped, repainted: it is where its `B` lands.
            if state.promptAwaitsRepaint {
                state.promptAwaitsRepaint = false
                movePromptToCursor()
            }
            state.sawPromptEnd = true
            // Only when 'B' is on the same row as 'A'; a multi-line prompt
            // under-estimates, the safe direction for an app-initiated `cd`.
            if state.promptRow == grid.absoluteRow(ofScreenRow: grid.cursor.row) {
                state.promptEndColumn = grid.cursor.column
                state.commandRecords.markPromptEnd(column: grid.cursor.column)
            }
        case 0x43:  // 'C' — the command is running, and its output starts here
            state.directoryCompletion = nil
            state.isCommandRunning = true
            state.shellMarksOutputStart = true
            state.promptAwaitsRepaint = false
            let outputRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            state.outputStartRow = outputRow
            state.commandRecords.markOutputStart(outputRow)
            // A command that printed nothing leaves the next prompt here; the
            // prompt mark wins.
            if grid.line(atAbsoluteRow: outputRow)?.mark.isPrompt != true {
                grid.setMark(.outputStart, atAbsoluteRow: outputRow)
            }
        case 0x44:  // 'D' — the command finished
            // Bracketed paste is the shell's to turn on, and only its line
            // editor does it, after `D` — zsh and bash after `A`, fish before
            // it. A command's own output can turn it on as well (`cat` of a
            // file holding `ESC [ ? 2004 h`), which silences the multi-line
            // paste warning under a shell that never reads the markers, such
            // as macOS's bash 3.2. Each finished command clears it.
            state.bracketedPasteEnabled = false
            // A program that pushed keyboard-protocol flags on the main
            // screen and died (a crash, SIGKILL) never popped them, and the
            // shell's line editor would get `CSI 99;5u` for Ctrl-C. Shells
            // that use the protocol push again for their next prompt, after
            // `D`.
            if !grid.isAlternateScreenActive {
                state.keyboardProtocol = KeyboardProtocolStack()
            }
            // One outcome per prompt. A second `D`, or one on the prompt's own
            // row before anything ran, is a doubled hook — fish 4 marks its
            // prompts itself, and a hook's `D` after fish's `A` closed a phantom
            // command with the last one's status. "Before anything ran" needs a
            // shell that sends `C`: without one, `clear` puts the cursor back
            // on a top-row prompt and a real command's `D` looks the same.
            let cursorRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            let nothingRan =
                state.shellMarksOutputStart && !state.isCommandRunning
                && state.promptRow == cursorRow
            if state.commandExitStatus != nil || nothingRan {
                break
            }
            state.isCommandRunning = false
            state.promptAwaitsRepaint = false
            let status = Self.exitStatus(payload)
            state.commandExitStatus = status
            state.finishedCommandExitStatus = status
            // Only a row still holding its prompt: `clear` erased the one it
            // was typed on, and colouring that drew a rule down an empty row.
            if let row = state.promptRow, grid.line(atAbsoluteRow: row)?.mark.isPrompt == true {
                grid.setMark(status == 0 ? .promptSucceeded : status == 130 ? .promptInterrupted : .promptFailed, atAbsoluteRow: row)
            }
            let endRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            state.commandRecords.finish(exitStatus: status, endRow: endRow, at: Date())
        default:
            break
        }
    }

    /// Nothing has run at the current prompt: no `C`, no `D` since its `A`.
    private var promptIsWaiting: Bool {
        !grid.isAlternateScreenActive && state.promptRow != nil && !state.isCommandRunning
            && state.commandExitStatus == nil
    }

    /// ED 2 at a waiting prompt — zsh's and bash's ⌃L — erases its mark, and
    /// the shell repaints it with no new `A`, so the next command's outcome
    /// had nowhere to land. The prompt moves on the repaint's `B`, not now:
    /// `ESC[2J ESC[H` erases before the cursor reaches the row the prompt is
    /// redrawn on. Only a repainting prompt sends `B`, never a running
    /// command, so this needs no sign that the shell sends `C`.
    mutating func promptErased() {
        if promptIsWaiting { state.promptAwaitsRepaint = true }
    }

    /// Clear Screen at a waiting prompt: nothing is repainted, and the next
    /// command is typed where Corta left the cursor, at the top. Moved now,
    /// for a shell that shows the prompt is waiting — it has sent `C` before,
    /// or this prompt's `B` — since without either a running command looks
    /// the same.
    mutating func screenClearedByUser() {
        guard promptIsWaiting, state.shellMarksOutputStart || state.sawPromptEnd else { return }
        movePromptToCursor()
    }

    private mutating func movePromptToCursor() {
        let row = grid.absoluteRow(ofScreenRow: grid.cursor.row)
        state.promptRow = row
        state.promptEndColumn = nil
        grid.setMark(.prompt, atAbsoluteRow: row)
        state.commandRecords.movePrompt(
            to: row, workingDirectory: state.workingDirectory,
            host: state.remoteContext?.host, at: Date())
    }

    /// A missing status is 0: "finished", not "failed".
    private static func exitStatus(_ payload: ArraySlice<UInt8>) -> Int {
        guard let separator = payload.firstIndex(of: 0x3B) else { return 0 }  // ';'
        var status = 0
        var sawDigit = false
        for byte in payload[payload.index(after: separator)...] {
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            status = status * 10 + Int(byte - 0x30)
            if status > 255 { return 255 }
        }
        return sawDigit ? status : 0
    }
}
