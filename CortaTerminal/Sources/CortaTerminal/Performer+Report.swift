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

    /// DECSCL — the announced conformance level (`CSI Ps ; Ps " p`), 61 for
    /// VT100 through 65 for VT500. Corta behaves as a VT500-class terminal
    /// and starts there; what the level actually gates is which sequences
    /// are allowed to answer, DECRQM being the one that matters (M6.5).
    public internal(set) var conformanceLevel = 65

    /// LNM — ECMA-48 §8.3.106, `CSI 20 h` / `CSI 20 l`. While set, LF, VT and
    /// FF each perform a carriage return as well as an index, and the Return
    /// key sends CR LF rather than CR.
    ///
    /// Implemented rather than reported: this is the mode a program sets when
    /// it wants to print bare `\n` and have the next line start at column
    /// zero. Answering "not recognised" and then not doing it produced the
    /// classic staircase — each line starting where the last one ended — for
    /// anything that trusted the answer.
    public internal(set) var newLineModeEnabled = false

    /// The kitty keyboard protocol's mode stack (M6.9). The app reads
    /// `current` to decide how to encode a key press.
    public internal(set) var keyboardProtocol = KeyboardProtocolStack()

    /// The colours OSC 10/11/12 report (M6.6). Seeded by the app from its
    /// palette so a query answers with what is actually on screen, and
    /// updated by the set forms.
    public internal(set) var dynamicColors = DynamicColors()

    /// OSC 133 shell integration (M7.2). The absolute row of the most
    /// recent prompt, so the exit status can be written back onto it however
    /// far the output has scrolled since.
    public internal(set) var promptRow: Int?

    /// Whether a command is running right now, between `OSC 133 ; C` and
    /// `OSC 133 ; D`. The honest answer to the question `TaskNotifier` used
    /// to guess at.
    public internal(set) var isCommandRunning = false

    /// The exit status of the command that just finished, until something
    /// reads it. `Terminal.takeFinishedCommand()` drains this — a
    /// notification must fire once per command, not once per frame.
    public internal(set) var finishedCommandExitStatus: Int?

    /// The last exit status seen, kept after `finishedCommandExitStatus` is
    /// drained.
    public internal(set) var commandExitStatus: Int?

    /// OSC 52 (M7.11). Text the child asked to put on the system clipboard,
    /// drained by the app. Never the other direction: the read form of OSC 52
    /// hands clipboard contents to the child, which is a data-exfiltration
    /// primitive, and it stays unimplemented (`SECURITY.md` §6).
    public internal(set) var pendingClipboardCopy: String?

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
        switch parameters.value(0, default: 0) {
        case 5:
            // DSR "operating status" — ECMA-48 §8.3.35, `CSI 5 n`, answered
            // `CSI 0 n`: ready, no malfunctions.
            //
            // This went unanswered, which is the one outcome a status query
            // must never get: it is the sequence a program sends precisely
            // *because* it wants to find out whether the terminal is alive,
            // so silence is read as "it is not" — and the ones that wait
            // without a timeout wait forever, with the terminal looking like
            // the thing that hung.
            state.outputBuffer.append(contentsOf: Array("\u{1B}[0n".utf8))
        case 6:
            state.outputBuffer.append(
                contentsOf: Array("\u{1B}[\(grid.cursor.row + 1);\(grid.cursor.column + 1)R".utf8)
            )
        default:
            break
        }
    }

    /// DECXCPR — `CSI ? 6 n`, the private cursor-position report, answered
    /// `CSI ? row ; column ; page R`.
    ///
    /// The same query as DSR 6 with a page number added, and it was
    /// unanswered for the same reason DSR 5 was: the private marker routed
    /// to a switch with no `n` case at all. Page is always 1 — Corta has one
    /// page and no DECPAM to switch it.
    mutating func reportExtendedCursorPosition(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 6 else { return }
        state.outputBuffer.append(
            contentsOf: Array(
                "\u{1B}[?\(grid.cursor.row + 1);\(grid.cursor.column + 1);1R".utf8)
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
