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

    /// Whether query responses are queued for the child.
    public var hasPendingOutput: Bool { !performer.state.outputBuffer.isEmpty }

    /// `?2004` — whether the child has enabled bracketed paste (M2.6).
    public var isBracketedPasteEnabled: Bool { performer.state.bracketedPasteEnabled }

    /// `?1006` — whether the child has asked for SGR-encoded mouse reports
    /// (M2.7).
    public var isSgrMouseEncodingEnabled: Bool { performer.state.sgrMouseEncodingEnabled }

    /// The window title set by OSC 0/2 (M2.8). Set-only: the title query is
    /// never answered (`SECURITY.md` §2.2).
    public var windowTitle: String? { performer.state.windowTitle }

    /// The working directory reported by OSC 7 (M2.8).
    public var workingDirectory: String? { performer.state.workingDirectory }

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
