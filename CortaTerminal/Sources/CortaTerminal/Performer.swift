/// Applies what the parser recognised to the grid.
///
/// This is the half of the emulator that knows what a sequence *means*. The
/// parser knows only its shape. Everything unrecognised is ignored cleanly:
/// `$TERM` claims `xterm-256color` (`DESIGN.md` §2.5), so programs send
/// sequences Corta does not implement, and skipping them is a correctness
/// requirement (`SECURITY.md` §3).
public struct Performer: ParserPerformer, Sendable {
    public var grid: Grid

    /// State that is not the grid: queued query responses, DEC mode flags,
    /// and the OSC-set title and working directory. The handlers live in the
    /// `Performer+Report/Modes/OSC` extensions; keeping the storage in one
    /// property keeps this struct's declaration — a file shared with other
    /// M2 tracks — out of their way.
    public var state = PerformerState()

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
        default: break  // BEL is M4.8; the rest have no effect on the grid.
        }
    }

    // MARK: - CSI dispatch

    public mutating func csiDispatch(_ sequence: CSISequence) {
        // A private marker makes a different sequence with the same final
        // byte — `CSI > c` is not `CSI c`. The ones M2 answers route here;
        // every other marker or intermediate form is ignored, which is the
        // correct and safe default (`SECURITY.md` §3).
        if sequence.privateMarker != 0 {
            guard sequence.intermediates.count == 0 else { return }
            switch (sequence.privateMarker, sequence.final) {
            case (0x3E, 0x63):  // DA2 — CSI > c
                reportSecondaryDeviceAttributes()
            case (0x3F, 0x68):  // DECSET — CSI ? Pm h
                applyPrivateModes(sequence.parameters, enabled: true)
            case (0x3F, 0x6C):  // DECRST — CSI ? Pm l
                applyPrivateModes(sequence.parameters, enabled: false)
            default:
                break
            }
            return
        }
        guard sequence.intermediates.count == 0 else { return }

        let parameters = sequence.parameters
        if performCursorControl(final: sequence.final, parameters: parameters) { return }
        if performErase(final: sequence.final, parameters: parameters) { return }
        switch sequence.final {
        case 0x63:  // DA1
            reportPrimaryDeviceAttributes()
        case 0x6D:  // SGR
            applyGraphicRendition(parameters)
        case 0x6E:  // DSR
            reportDeviceStatus(parameters)
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
