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

/// Applies what the parser recognised to the grid.
///
/// This is the half of the emulator that knows what a sequence *means*. The
/// parser knows only its shape. Everything unrecognised is ignored cleanly:
/// `$TERM` claims `xterm-256color` (`DECISIONS.md` D08), so programs send
/// sequences Corta does not implement, and skipping them is a correctness
/// requirement (`SECURITY.md` §3).
struct Performer: ParserPerformer, Sendable {
    var grid: Grid

    /// State that is not the grid: queued query responses, DEC mode flags,
    /// and the OSC-set title and working directory. The handlers live in the
    /// `Performer+Report/Modes/OSC` extensions; keeping the storage in one
    /// property keeps this struct's declaration small and out of their
    /// way.
    var state = PerformerState()

    var imageAllowanceProvider: (@Sendable () -> Int)?

    /// The secret the pane's own zsh widget puts before each OSC 134
    /// report; nil believes none. Outside `state`, so a reset keeps it.
    var directoryCompletionToken: [UInt8]?

    init(grid: Grid) {
        self.grid = grid
    }

    // MARK: - Text and C0 controls

    mutating func print(_ scalar: UInt32) {
        grid.write(scalar)
    }

    mutating func printASCII(_ bytes: ArraySlice<UInt8>) {
        grid.writeASCII(bytes)
    }

    mutating func execute(_ control: UInt8) {
        switch control {
        case 0x08: grid.backspace()
        case 0x09: grid.tab()
        // LF, VT and FF all move down one row without changing the column —
        // unless LNM is set, which makes each of them a new *line* rather
        // than a new row (ECMA-48 §8.3.106).
        case 0x0A, 0x0B, 0x0C:
            grid.lineFeed()
            if state.newLineModeEnabled { grid.carriageReturn() }
        case 0x0D: grid.carriageReturn()
        case 0x07: state.bellRequested = true  // BEL
        default: break  // The rest have no effect on the grid.
        }
    }

    // MARK: - CSI dispatch

    mutating func csiDispatch(_ sequence: CSISequence) {
        // A private marker or an intermediate makes it a different sequence
        // with the same final byte — `CSI ? 25 h` is not `CSI 25 h`, and
        // `CSI > c` is not `CSI c`. The ones Corta answers route here; every
        // other marker or intermediate form is ignored cleanly, which is the
        // correct and safe default (`SECURITY.md` §3).
        if sequence.privateMarker != 0 {
            dispatchPrivateCSI(sequence)
        } else if sequence.intermediates.count > 0 {
            dispatchIntermediateCSI(sequence)
        } else {
            dispatchPlainCSI(final: sequence.final, parameters: sequence.parameters)
        }
    }

    /// `CSI ? …`, `CSI > …`, `CSI < …` and `CSI = …`.
    private mutating func dispatchPrivateCSI(_ sequence: CSISequence) {
        // DECRQM's private form carries a `$` intermediate: `CSI ? Ps $ p`
        // is a question about a mode, not a mode change.
        if sequence.intermediates.count == 1, sequence.intermediates[0] == 0x24,
            sequence.final == 0x70, sequence.privateMarker == 0x3F
        {
            reportMode(sequence.parameters, isPrivate: true)
            return
        }
        guard sequence.intermediates.count == 0 else { return }
        switch (sequence.privateMarker, sequence.final) {
        case (0x3E, 0x63):  // DA2 — CSI > c
            reportSecondaryDeviceAttributes()
        case (0x3E, 0x71):  // XTVERSION — CSI > Ps q
            reportVersion(sequence.parameters)
        // The kitty keyboard protocol. Four private markers on
        // one final byte: `?` queries, `>` pushes, `<` pops, `=` sets.
        case (0x3F, 0x75):
            reportKeyboardProtocol()
        case (0x3E, 0x75):
            pushKeyboardProtocol(sequence.parameters)
        case (0x3C, 0x75):
            popKeyboardProtocol(sequence.parameters)
        case (0x3D, 0x75):
            setKeyboardProtocol(sequence.parameters)
        case (0x3F, 0x6E):  // DECXCPR — CSI ? Ps n
            reportExtendedCursorPosition(sequence.parameters)
        case (0x3F, 0x68):  // DECSET — CSI ? Pm h
            applyPrivateModes(sequence.parameters, enabled: true)
            _ = performAlternateScreenMode(final: sequence.final, parameters: sequence.parameters)
        case (0x3F, 0x6C):  // DECRST — CSI ? Pm l
            applyPrivateModes(sequence.parameters, enabled: false)
            _ = performAlternateScreenMode(final: sequence.final, parameters: sequence.parameters)
        default:
            break
        }
    }

    /// DECSCUSR (`CSI Ps SP q`) and its kin carry an intermediate byte.
    private mutating func dispatchIntermediateCSI(_ sequence: CSISequence) {
        // DECRQM, ANSI form — `CSI Ps $ p`.
        if sequence.intermediates.count == 1, sequence.intermediates[0] == 0x24,
            sequence.final == 0x70
        {
            reportMode(sequence.parameters, isPrivate: false)
            return
        }
        // DECSCL — `CSI Ps ; Ps " p`, the announced conformance level.
        if sequence.intermediates.count == 1, sequence.intermediates[0] == 0x22,
            sequence.final == 0x70
        {
            setConformanceLevel(sequence.parameters)
            return
        }
        _ = performIntermediate(
            final: sequence.final,
            intermediates: sequence.intermediates,
            parameters: sequence.parameters
        )
    }

    /// A CSI sequence with neither a private marker nor an intermediate.
    private mutating func dispatchPlainCSI(final: UInt8, parameters: Parameters) {
        // SGR dominates coloured shell/log output. It cannot be a cursor,
        // erase or editing command, so do not make every colour change walk
        // those three dispatch tables first.
        if final == 0x6D {
            applyGraphicRendition(parameters)
            return
        }
        // SM / RM — `CSI Pm h` / `CSI Pm l`, the ANSI modes. Distinct from
        // DECSET/DECRST above, which carry the `?` marker; `CSI 4 h` (insert
        // mode) and `CSI ? 4 h` (smooth scroll) are different sequences, and
        // must not land in the same place.
        if final == 0x68 {
            applyAnsiModes(parameters, enabled: true)
            return
        }
        if final == 0x6C {
            applyAnsiModes(parameters, enabled: false)
            return
        }
        if performCursorControl(final: final, parameters: parameters) { return }
        if performErase(final: final, parameters: parameters) { return }
        if performEditing(final: final, parameters: parameters) { return }
        switch final {
        case 0x63:  // DA1
            reportPrimaryDeviceAttributes()
        case 0x6E:  // DSR
            reportDeviceStatus(parameters)
        case 0x74:  // CSI Ps t — window manipulation; only the size report
            reportWindowManipulation(parameters)
        default:
            break
        }
    }

    // MARK: - SGR

    /// SGR — ECMA-48 §8.3.117, plus the xterm 256-colour and direct-colour
    /// extensions.
    ///
    /// `CSI m` with no parameters is `CSI 0 m`: reset.
    private mutating func applyGraphicRendition(_ parameters: Parameters) {
        guard parameters.count > 0 else {
            grid.pen.reset()
            return
        }

        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            // The colon-joined parameters after `code`, which belong to it.
            var subparameterCount = 0
            while parameters.isSubparameter(index + 1 + subparameterCount) { subparameterCount += 1 }
            switch code {
            case 0: grid.pen.reset()
            case 1: grid.pen.attributes.insert(.bold)
            case 2: grid.pen.attributes.insert(.dim)
            case 3: grid.pen.attributes.insert(.italic)
            case 4 where subparameterCount > 0:
                Self.setUnderline(style: parameters[index + 1], on: &grid.pen.attributes)
            case 4: Self.setUnderline(style: 1, on: &grid.pen.attributes)
            case 5, 6: grid.pen.attributes.insert(.blink)
            case 7: grid.pen.attributes.insert(.reverse)
            case 8: grid.pen.attributes.insert(.invisible)
            case 9: grid.pen.attributes.insert(.strikethrough)
            // Doubly underlined, as ECMA-48, xterm, VTE and kitty read it;
            // "not bold" is the older Linux-console reading.
            case 21: Self.setUnderline(style: 2, on: &grid.pen.attributes)
            case 22: grid.pen.attributes.subtract([.bold, .dim])
            case 23: grid.pen.attributes.remove(.italic)
            case 24: grid.pen.attributes.subtract(.anyUnderline)
            case 25: grid.pen.attributes.remove(.blink)
            case 27: grid.pen.attributes.remove(.reverse)
            case 28: grid.pen.attributes.remove(.invisible)
            case 29: grid.pen.attributes.remove(.strikethrough)
            case 30...37: grid.pen.foreground = .indexed(UInt8(code - 30))
            case 39: grid.pen.foreground = .default
            case 40...47: grid.pen.background = .indexed(UInt8(code - 40))
            case 49: grid.pen.background = .default
            case 90...97: grid.pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: grid.pen.background = .indexed(UInt8(code - 100 + 8))
            // A `where` binds to one pattern only; each needs its own.
            case 38 where subparameterCount > 0, 48 where subparameterCount > 0:
                if let color = Self.extendedColor(subparameters: parameters, after: index, count: subparameterCount) {
                    if code == 38 { grid.pen.foreground = color } else { grid.pen.background = color }
                }
            // The underline's colour: not drawn, but its operands must not be
            // read as attributes — `58;2;r;g;b` would turn on dim.
            case 58 where subparameterCount == 0:
                guard let (_, consumed) = Self.extendedColor(parameters, at: index) else { return }
                index += consumed - 1
            case 38, 48:
                guard let (color, consumed) = Self.extendedColor(parameters, at: index) else {
                    // Malformed: the parameters that would say which colour
                    // are missing. Stop rather than read the rest of the
                    // sequence as attribute codes.
                    return
                }
                if code == 38 { grid.pen.foreground = color } else { grid.pen.background = color }
                index += consumed - 1
            default: break
            }
            index += 1 + subparameterCount
        }
    }

    /// `SGR 4:n`: 0 none, 1 single, 2 double, 3 curly; 4 (dotted) and 5
    /// (dashed) draw single.
    private static func setUnderline(style: UInt16, on attributes: inout CellAttributes) {
        attributes.subtract(.anyUnderline)
        switch style {
        case 0: break
        case 2: attributes.formUnion([.underline, .doubleUnderline])
        case 3: attributes.formUnion([.underline, .curlyUnderline])
        default: attributes.insert(.underline)
        }
    }

    /// The colon forms, ITU T.416: `38:5:n`, `38:2:r:g:b` and
    /// `38:2:id:r:g:b` with its colour-space id, empty or not.
    private static func extendedColor(subparameters parameters: Parameters, after index: Int, count: Int) -> Color? {
        switch parameters[index + 1] {
        case 5 where count >= 2:
            return .indexed(UInt8(min(parameters[index + 2], 255)))
        case 2 where count >= 4:
            let first = index + (count >= 5 ? 3 : 2)
            return .rgb(
                UInt8(min(parameters[first], 255)),
                UInt8(min(parameters[first + 1], 255)),
                UInt8(min(parameters[first + 2], 255)))
        default:
            return nil
        }
    }

    /// Reads `38;5;n` or `38;2;r;g;b` (and the `48` background forms),
    /// returning the colour and how many parameters it spanned.
    ///
    /// The colon-separated forms are `extendedColor(subparameters:after:count:)`.
    private static func extendedColor(_ parameters: Parameters, at index: Int) -> (Color, Int)? {
        switch parameters[index + 1] {
        case 5 where index + 2 < parameters.count:
            return (.indexed(UInt8(min(parameters[index + 2], 255))), 3)
        case 2 where index + 4 < parameters.count:
            let color = Color.rgb(
                UInt8(min(parameters[index + 2], 255)),
                UInt8(min(parameters[index + 3], 255)),
                UInt8(min(parameters[index + 4], 255))
            )
            return (color, 5)
        default:
            return nil
        }
    }

    /// A reflow renumbers rows — a resize, or leaving the alternate screen
    /// after one reflowed the parked main screen. Every absolute row held
    /// outside the grid follows its row, before anything else reads them.
    mutating func applyRowRemaps() {
        guard !grid.rowRemaps.isEmpty else { return }
        let remaps = grid.rowRemaps
        grid.rowRemaps.removeAll()
        for remap in remaps {
            state.commandRecords.remapRows(remap)
            if let row = state.promptRow {
                state.promptEndColumn = state.promptEndColumn.flatMap {
                    remap.promptEndColumn(promptRow: row, column: $0)
                }
            }
            state.promptRow = state.promptRow.map(remap.map)
            state.outputStartRow = state.outputStartRow.map(remap.map)
        }
    }
}
