/// Terminal state that is not the grid, owned by the performer and surfaced
/// read-only through `Terminal` and `TerminalSession`.
public struct PerformerState: Sendable {
    /// Query responses waiting to be written to the child's stdin.
    ///
    /// Fixed-format only: a response is a constant or numeric cursor
    /// coordinates, never text the input stream supplied (`SECURITY.md`
    /// §2.1–2.2). The performer holds no PTY; `TerminalSession` drains this
    /// after every `feed` and writes it.
    public internal(set) var outputBuffer: [UInt8] = []

    /// `?2004` — bracketed paste (M2.6). Off until the child turns it on.
    public internal(set) var bracketedPasteEnabled = false

    /// `?1006` — SGR encoding for mouse reports (M2.7). Reporting itself
    /// (`?1000` and friends) is the app layer's side of M2.7.
    public internal(set) var sgrMouseEncodingEnabled = false

    /// `?2026` — synchronized output (M4.3). While set, the app must present
    /// no frame; the core decides nothing about presentation, only tracks
    /// the mode.
    public internal(set) var synchronizedOutputEnabled = false

    /// Set by a BEL (M4.8, core side). The core decides nothing about
    /// audible, visual or muted — that is the app's business. `Terminal`
    /// exposes this write-only-from-here via `takeBell()`.
    public internal(set) var bellRequested = false

    /// The window title most recently set by OSC 0/2 (M2.8). Never reported
    /// back to the child — the title query is a command-injection vector
    /// (`SECURITY.md` §2.2) and stays unimplemented.
    public internal(set) var windowTitle: String?

    /// The working directory most recently reported by OSC 7 (M2.8), as a
    /// path. A hint for new tabs and splits (M5.5), nothing more.
    public internal(set) var workingDirectory: String?

    /// `?1004` — focus reporting (M6.7). While set, the app sends `CSI I` on
    /// focus and `CSI O` on blur, which is what Neovim's `autoread` and
    /// tmux's `focus-events` are waiting for.
    public internal(set) var focusReportingEnabled = false

    /// The kitty keyboard protocol's mode stack (M6.9). The app reads
    /// `current` to decide how to encode a key press.
    public internal(set) var keyboardProtocol = KeyboardProtocolStack()

    /// The colours OSC 10/11/12 report (M6.6). Seeded by the app from its
    /// palette so a query answers with what is actually on screen, and
    /// updated by the set forms.
    public internal(set) var dynamicColors = DynamicColors()

    public init() {}
}

/// The three colours the OSC 10/11/12 pair of set and query forms names:
/// default foreground, default background and the cursor (M6.6).
///
/// 8 bits per channel. The report form is xterm's 16-bit `rgb:` notation,
/// which is produced by doubling each byte — a fixed transformation of
/// numeric state, never stream-supplied text (`SECURITY.md` §2.2).
public struct DynamicColors: Sendable, Equatable {
    public var foreground: (red: UInt8, green: UInt8, blue: UInt8)
    public var background: (red: UInt8, green: UInt8, blue: UInt8)
    public var cursor: (red: UInt8, green: UInt8, blue: UInt8)

    public init(
        foreground: (red: UInt8, green: UInt8, blue: UInt8) = (245, 245, 245),
        background: (red: UInt8, green: UInt8, blue: UInt8) = (35, 40, 51),
        cursor: (red: UInt8, green: UInt8, blue: UInt8) = (245, 245, 245)
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    public static func == (lhs: DynamicColors, rhs: DynamicColors) -> Bool {
        lhs.foreground == rhs.foreground && lhs.background == rhs.background
            && lhs.cursor == rhs.cursor
    }
}

/// Query responses — M2.2 (`CONFORMANCE.md` §1.2). A program that asks and
/// hears nothing stalls or misdetects: vim hangs at startup without DA1.
///
/// Every response is a fixed byte string or numeric coordinates — no text
/// from the input stream is ever echoed back (`SECURITY.md` §2.2).
extension Performer {
    /// DA1 — `CSI c` (ctlseqs "Send Device Attributes (Primary DA)").
    ///
    /// `CSI ? 62 ; Ps c` is the VT220 form. The parameters are the ones
    /// Corta actually honours — 1 = 132 columns (any width works) and
    /// 22 = ANSI colour (SGR) — because claiming more invites probes that
    /// would go unanswered.
    private static let primaryDeviceAttributes = Array("\u{1B}[?62;1;22c".utf8)

    /// DA2 — `CSI > c` (ctlseqs "Send Device Attributes (Secondary DA)":
    /// `CSI > Pp ; Pv ; Pc c`). Pp 1 = VT220, matching the primary answer;
    /// Pv 0 and Pc 0 are "no version, no cartridge", so capability
    /// detection falls back to conservative behaviour.
    private static let secondaryDeviceAttributes = Array("\u{1B}[>1;0;0c".utf8)

    mutating func reportPrimaryDeviceAttributes() {
        state.outputBuffer.append(contentsOf: Self.primaryDeviceAttributes)
    }

    mutating func reportSecondaryDeviceAttributes() {
        state.outputBuffer.append(contentsOf: Self.secondaryDeviceAttributes)
    }

    /// DSR — `CSI Ps n`. Only the cursor-position report (Ps = 6) is
    /// implemented: CPR is `CSI Pl ; Pc R` with 1-based row and column.
    mutating func reportDeviceStatus(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 6 else { return }
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}[\(grid.cursor.row + 1);\(grid.cursor.column + 1)R".utf8)
        )
    }

    /// Window manipulation — `CSI Ps t` (ctlseqs "Window manipulation").
    /// Only Ps = 18, "report the size of the text area in characters", is
    /// implemented, answered `CSI 8 ; rows ; columns t`: esctest's harness
    /// asks it before every test, and the response is fixed-format numeric
    /// state. The title report (Ps = 21) is a command-injection vector and
    /// is never implemented (`SECURITY.md` §2.2).
    mutating func reportWindowManipulation(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 18 else { return }
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}[8;\(grid.rows);\(grid.columns)t".utf8)
        )
    }
}
