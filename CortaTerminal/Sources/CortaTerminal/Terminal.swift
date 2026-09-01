/// A terminal: bytes in, grid out.
///
/// This is the unit a golden test feeds and a viewport renders
/// (`DESIGN.md` §2.4) — no singletons, no window, no PTY. `TerminalSession`
/// adds the PTY around it in M1.19.
///
/// Nonisolated: it runs on the reader thread (`DESIGN.md` §2.2).
public struct Terminal: Sendable {
    public var grid: Grid

    public init(rows: Int = 24, columns: Int = 80) {
        self.grid = Grid(rows: rows, columns: columns)
    }

    /// Consumes a chunk of PTY output. A chunk boundary may fall anywhere —
    /// in the middle of a UTF-8 sequence or an escape sequence — so all
    /// decoding state lives in the terminal, not in a call.
    public mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            switch byte {
            case 0x08: grid.backspace()
            case 0x09: grid.tab()
            case 0x0A, 0x0B, 0x0C: grid.lineFeed()
            case 0x0D: grid.carriageReturn()
            case 0x20...0x7E: grid.write(UInt32(byte))
            default: break  // The parser takes over in M1.8.
            }
        }
    }

    public func dump() -> String {
        grid.dump()
    }
}
