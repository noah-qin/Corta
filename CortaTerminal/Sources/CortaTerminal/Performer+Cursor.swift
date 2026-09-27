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

extension Performer {
    /// Cursor motion, absolute forms included: Ink (Claude Code) lays a line out
    /// in segments joined by `CSI n G`, and without it a whole screen collapsed
    /// its spacing. `false` falls through to the next dispatch category.
    mutating func performCursorControl(final: UInt8, parameters: Parameters) -> Bool {
        switch final {
        case 0x41:  // CUU
            grid.moveCursorUp(parameters.value(0, default: 1))
        case 0x42:  // CUD
            grid.moveCursorDown(parameters.value(0, default: 1))
        case 0x43:  // CUF
            grid.moveCursorRight(parameters.value(0, default: 1))
        case 0x44:  // CUB
            grid.moveCursorLeft(parameters.value(0, default: 1))
        case 0x45:  // CNL
            grid.moveToNextLine(parameters.value(0, default: 1))
        case 0x46:  // CPL
            grid.moveToPreviousLine(parameters.value(0, default: 1))
        case 0x48, 0x66:  // CUP, HVP — one-based on the wire, zero-based here
            grid.moveCursor(
                row: parameters.value(0, default: 1) - 1,
                column: parameters.value(1, default: 1) - 1
            )
        case 0x47, 0x60:  // CHA, HPA — absolute column, row unchanged
            grid.moveCursor(
                row: grid.cursor.row,
                column: parameters.value(0, default: 1) - 1
            )
        case 0x61:  // HPR — relative column, same effect as CUF
            grid.moveCursorRight(parameters.value(0, default: 1))
        case 0x64:  // VPA — absolute row, column unchanged
            grid.moveCursor(
                row: parameters.value(0, default: 1) - 1,
                column: grid.cursor.column
            )
        case 0x65:  // VPR — relative row, same effect as CUD
            grid.moveCursorDown(parameters.value(0, default: 1))
        case 0x49:  // CHT — forward horizontal tabulation
            grid.tabForward(parameters.value(0, default: 1))
        case 0x5A:  // CBT — backward horizontal tabulation
            grid.tabBackward(parameters.value(0, default: 1))
        // Bare `CSI s`/`CSI u` alias DECSC/DECRC, as xterm does without DECLRMM.
        // Zero parameters only: kitty's key report `CSI 97;5u` reaches this switch
        // too and must not restore the cursor.
        case 0x73 where parameters.count == 0:  // SCOSC
            grid.saveCursor()
        case 0x75 where parameters.count == 0:  // SCORC
            grid.restoreCursor()
        default:
            return false
        }
        return true
    }
}
