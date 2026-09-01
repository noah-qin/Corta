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
            // ED 3 (xterm): erase the scrollback. Not in ECMA-48, but tmux
            // and clear(1) both send it.
            case 3: grid.scrollback.removeAll()
            default: break
            }
        case 0x6D:  // SGR
            applyGraphicRendition(parameters)
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
            switch code {
            case 0: grid.pen.reset()
            case 1: grid.pen.attributes.insert(.bold)
            case 2: grid.pen.attributes.insert(.dim)
            case 3: grid.pen.attributes.insert(.italic)
            case 4: grid.pen.attributes.insert(.underline)
            case 5, 6: grid.pen.attributes.insert(.blink)
            case 7: grid.pen.attributes.insert(.reverse)
            case 8: grid.pen.attributes.insert(.invisible)
            case 9: grid.pen.attributes.insert(.strikethrough)
            // 21 is doubly-underlined in ECMA-48 and "not bold" in some
            // terminals. Neither reading is safe to guess, so it is ignored
            // until there is a double underline to turn on.
            case 22: grid.pen.attributes.subtract([.bold, .dim])
            case 23: grid.pen.attributes.remove(.italic)
            case 24: grid.pen.attributes.remove(.underline)
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
            index += 1
        }
    }

    /// Reads `38;5;n` or `38;2;r;g;b` (and the `48` background forms),
    /// returning the colour and how many parameters it spanned.
    ///
    /// The colon-separated form `38:2::r:g:b` needs sub-parameters, which the
    /// parser sends to the ignore state until M2.
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
}
