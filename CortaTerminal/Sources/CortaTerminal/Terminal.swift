/// A terminal: bytes in, grid out.
///
/// This is the unit a golden test feeds and a viewport renders
/// (`DESIGN.md` §2.4) — no singletons, no window, no PTY. `TerminalSession`
/// adds the PTY around it in M1.19.
///
/// Nonisolated: it runs on the reader thread (`DESIGN.md` §2.2).
public struct Terminal: Sendable {
    private var parser = Parser()
    private var performer: Performer

    public init(
        rows: Int = 24,
        columns: Int = 80,
        scrollbackLimit: Int = Scrollback.defaultLimit
    ) {
        self.performer = Performer(
            grid: Grid(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
        )
    }

    public var grid: Grid {
        get { performer.grid }
        set { performer.grid = newValue }
    }

    /// Consumes a chunk of PTY output. A chunk boundary may fall anywhere —
    /// in the middle of a UTF-8 character or an escape sequence — so all
    /// decoding state lives in the terminal, not in a call.
    public mutating func feed(_ bytes: some Sequence<UInt8>) {
        parser.parse(bytes, performer: &performer)
    }

    /// PTY reads are contiguous. Preserve that fact so `Parser` can batch
    /// printable ASCII instead of erasing it behind `some Sequence`.
    public mutating func feed(_ bytes: [UInt8]) {
        parser.parse(bytes, performer: &performer)
    }

    /// Whether query responses are queued for the child.
    public var hasPendingOutput: Bool { !performer.state.outputBuffer.isEmpty }

    /// `?2004` — whether the child has enabled bracketed paste (M2.6).
    public var isBracketedPasteEnabled: Bool { performer.state.bracketedPasteEnabled }

    /// `?1006` — whether the child has asked for SGR-encoded mouse reports
    /// (M2.7).
    public var isSgrMouseEncodingEnabled: Bool { performer.state.sgrMouseEncodingEnabled }

    /// `?2026` — whether synchronized output is active (M4.3). While true
    /// the shell must present no frame; when it goes false, present once.
    public var isSynchronizedOutputEnabled: Bool { performer.state.synchronizedOutputEnabled }

    /// `?1004` — whether the child has asked to be told about focus changes
    /// (M6.7). The app sends `CSI I` / `CSI O` while this is true.
    public var isFocusReportingEnabled: Bool { performer.state.focusReportingEnabled }

    /// The colours OSC 10/11/12 report (M6.6). The app seeds these from its
    /// palette so a query answers with what is actually drawn; the child can
    /// then change them, and the app reads them back to render.
    public var dynamicColors: DynamicColors {
        get { performer.state.dynamicColors }
        set { performer.state.dynamicColors = newValue }
    }

    /// The kitty keyboard protocol flags in force (M6.9). The app encodes
    /// key presses according to these.
    public var keyboardEnhancements: KeyboardEnhancementFlags {
        performer.state.keyboardProtocol.current
    }

    /// Consumes a pending BEL (M4.8): true at most once per bell, false
    /// otherwise. The app decides what a bell does; the core only reports
    /// that one happened.
    public mutating func takeBell() -> Bool {
        let requested = performer.state.bellRequested
        performer.state.bellRequested = false
        return requested
    }

    /// The window title set by OSC 0/2 (M2.8). Set-only: the title query is
    /// never answered (`SECURITY.md` §2.2).
    public var windowTitle: String? { performer.state.windowTitle }

    /// The working directory reported by OSC 7 (M2.8).
    public var workingDirectory: String? { performer.state.workingDirectory }

    /// Whether the shell says a command is running (OSC 133, M7.2). `false`
    /// when the shell emits no shell-integration sequences at all, which is
    /// why the app still keeps its keystroke heuristic as a fallback.
    public var isCommandRunning: Bool { performer.state.isCommandRunning }

    /// Whether this session has ever emitted an OSC 133 mark — i.e. whether
    /// its shell has integration configured. The app uses this to choose
    /// between the exact command boundaries and its own heuristic.
    public var hasShellIntegration: Bool { performer.state.promptRow != nil }

    /// Consumes the exit status of a command that just finished (OSC 133 D).
    /// Drained, like `takeBell`: a notification fires once per command, and a
    /// value left in place would fire on every frame after it.
    public mutating func takeFinishedCommand() -> Int? {
        let status = performer.state.finishedCommandExitStatus
        performer.state.finishedCommandExitStatus = nil
        return status
    }

    /// Consumes text the child asked to put on the system clipboard via OSC
    /// 52 (M7.11). The app decides whether to honour it; the core never
    /// touches a pasteboard, and the *read* direction does not exist.
    public mutating func takeClipboardCopy() -> String? {
        let text = performer.state.pendingClipboardCopy
        performer.state.pendingClipboardCopy = nil
        return text
    }

    /// Drains the queued query responses. `TerminalSession` calls this after
    /// every `feed` and writes the bytes to the PTY; tests read them
    /// directly, without a PTY. The buffer carries fixed-format response
    /// bytes only — never stream-supplied text (`SECURITY.md` §2.1).
    public mutating func takeOutput() -> [UInt8] {
        let output = performer.state.outputBuffer
        performer.state.outputBuffer = []
        return output
    }

    public func dump(options: DumpOptions = .default) -> String {
        performer.grid.dump(options: options)
    }
}
