/// Applies what the parser recognised to the grid.
///
/// This is the half of the emulator that knows what a sequence *means*. The
/// parser knows only its shape. Everything unrecognised is ignored cleanly:
/// `$TERM` claims `xterm-256color` (`DESIGN.md` §2.5), so programs send
/// sequences Corta does not implement, and skipping them is a correctness
/// requirement (`SECURITY.md` §3).
public struct Performer: ParserPerformer, Sendable {
    public var grid: Grid

    public init(grid: Grid) {
        self.grid = grid
    }

    // MARK: - Text and C0 controls

    public mutating func print(_ scalar: UInt32) {
        grid.write(scalar)
    }

    public mutating func execute(_ control: UInt8) {
        switch control {
        case 0x08: grid.backspace()
        case 0x09: grid.tab()
        // LF, VT and FF all move down one row without changing the column.
        case 0x0A, 0x0B, 0x0C: grid.lineFeed()
        case 0x0D: grid.carriageReturn()
        default: break  // BEL is M4.7; the rest have no effect on the grid.
        }
    }

    // MARK: - CSI

    public mutating func csiDispatch(_ sequence: CSISequence) {
        // A private marker or an intermediate makes it a different sequence
        // with the same final byte — `CSI ? 25 h` is not `CSI 25 h`. None of
        // those are implemented yet, and guessing would be worse than
        // ignoring them.
        guard sequence.privateMarker == 0, sequence.intermediates.count == 0 else { return }

        let parameters = sequence.parameters
        switch sequence.final {
        case 0x41:  // CUU
            grid.moveCursorUp(parameters.value(0, default: 1))
        case 0x42:  // CUD
            grid.moveCursorDown(parameters.value(0, default: 1))
        case 0x43:  // CUF
            grid.moveCursorRight(parameters.value(0, default: 1))
        case 0x44:  // CUB
            grid.moveCursorLeft(parameters.value(0, default: 1))
        case 0x48, 0x66:  // CUP, HVP — one-based on the wire, zero-based here
            grid.moveCursor(
                row: parameters.value(0, default: 1) - 1,
                column: parameters.value(1, default: 1) - 1
            )
        case 0x4A:  // ED
            switch parameters[0] {
            case 0: grid.eraseDisplay(.toEnd)
            case 1: grid.eraseDisplay(.toStart)
            case 2: grid.eraseDisplay(.all)
            default: break  // ED 3 erases the scrollback; M1.14.
            }
        case 0x4B:  // EL
            switch parameters[0] {
            case 0: grid.eraseLine(.toEnd)
            case 1: grid.eraseLine(.toStart)
            case 2: grid.eraseLine(.all)
            default: break
            }
        default:
            break
        }
    }
}
