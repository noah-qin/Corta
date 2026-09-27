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
            state.promptRow = row
            state.commandExitStatus = nil
            // Until this prompt's own 'B', a `cd` must not read the last one's.
            state.promptEndColumn = nil
            grid.setMark(.prompt, atAbsoluteRow: row)
            state.commandRecords.begin(
                promptRow: row, workingDirectory: state.workingDirectory,
                host: state.remoteContext?.host, at: Date())
        case 0x42:  // 'B' — command line starts
            // Only when 'B' is on the same row as 'A'; a multi-line prompt
            // under-estimates, the safe direction for an app-initiated `cd`.
            if state.promptRow == grid.absoluteRow(ofScreenRow: grid.cursor.row) {
                state.promptEndColumn = grid.cursor.column
                state.commandRecords.markPromptEnd(column: grid.cursor.column)
            }
        case 0x43:  // 'C' — the command is running, and its output starts here
            state.isCommandRunning = true
            let outputRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            state.outputStartRow = outputRow
            state.commandRecords.markOutputStart(outputRow)
            // A command that printed nothing leaves the next prompt here; the
            // prompt mark wins.
            if grid.line(atAbsoluteRow: outputRow)?.mark.isPrompt != true {
                grid.setMark(.outputStart, atAbsoluteRow: outputRow)
            }
        case 0x44:  // 'D' — the command finished
            state.isCommandRunning = false
            let status = Self.exitStatus(payload)
            state.commandExitStatus = status
            state.finishedCommandExitStatus = status
            if let row = state.promptRow {
                grid.setMark(status == 0 ? .promptSucceeded : .promptFailed, atAbsoluteRow: row)
            }
            let endRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            state.commandRecords.finish(exitStatus: status, endRow: endRow, at: Date())
        default:
            break
        }
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
