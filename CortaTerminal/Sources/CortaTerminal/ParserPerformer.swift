/// What a parser tells its performer.
///
/// The parser has no screen knowledge: it recognises the shape of a sequence
/// and says so. Deciding that `CSI 2 J` clears the screen is the performer's
/// job, and keeping the two apart is what lets the state machine be tested
/// against the byte stream alone (`DESIGN.md` §4).
///
/// Everything has a default no-op, so a performer implements only what it
/// handles and an unimplemented sequence is ignored cleanly, which is a
/// requirement rather than an oversight (`SECURITY.md` §3): `$TERM` claims
/// `xterm-256color`, so programs will send sequences Corta does not have.
public protocol ParserPerformer {
    /// A printable character.
    mutating func print(_ scalar: UInt32)

    /// A contiguous run of printable ASCII bytes in the ground state.
    /// Keeping this as a separate callback lets the overwhelmingly common
    /// terminal-output case avoid one parser state-machine dispatch and one
    /// protocol call per byte. The default preserves compatibility for small
    /// performers used by parser tests.
    mutating func printASCII(_ bytes: ArraySlice<UInt8>)

    /// A C0 control that acts immediately — `\r`, `\n`, `\t`, `\b`, BEL.
    mutating func execute(_ control: UInt8)

    /// `ESC` followed by intermediates and a final byte, e.g. `ESC ( B`.
    mutating func escapeDispatch(intermediates: Intermediates, final: UInt8)

    /// A complete CSI sequence.
    mutating func csiDispatch(_ sequence: CSISequence)

    /// A complete OSC string: everything between `ESC ]` and its terminator,
    /// already bounded by `Parser.maxStringLength`. Raw bytes, because an
    /// OSC payload is not necessarily text.
    mutating func oscDispatch(_ bytes: ArraySlice<UInt8>)
}

extension ParserPerformer {
    public mutating func printASCII(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { print(UInt32(byte)) }
    }

    public mutating func escapeDispatch(intermediates: Intermediates, final: UInt8) {}
    public mutating func csiDispatch(_ sequence: CSISequence) {}
    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {}
}
