/// An incremental UTF-8 decoder over a byte stream.
///
/// A PTY read boundary can fall anywhere, including between the second and
/// third byte of a CJK character, so decoding state lives here across calls
/// rather than in a buffer the caller must re-assemble.
///
/// Every byte from the PTY is hostile (`SECURITY.md` §1): malformed input
/// yields U+FFFD and never traps, never consumes unbounded memory, and never
/// desynchronises the stream. The rules are the ones in the WHATWG Encoding
/// Standard's UTF-8 decoder, which is also what xterm and every other modern
/// terminal implement:
///
/// - Overlong encodings are rejected — `C0 80` is not NUL. Accepting them
///   lets a filter that scans for ASCII bytes be bypassed.
/// - Surrogates U+D800–U+DFFF are rejected; they are not scalars.
/// - Anything above U+10FFFF is rejected.
/// - A byte that cannot continue the sequence in progress is *not* consumed
///   by that sequence: the sequence yields U+FFFD and the byte is
///   reinterpreted as a fresh start. That is what keeps a truncated sequence
///   followed by `ESC` from swallowing the escape.
///
/// Works in `UInt8` and `UInt32`; no `String` (`PERFORMANCE.md` §3).
public struct UTF8Decoder: Sendable {
    /// What one byte produced. A byte can yield two scalars, because a
    /// malformed sequence is reported at the moment the byte that ends it
    /// arrives, and that byte may itself be a character.
    public enum Result: Equatable, Sendable {
        /// More bytes are needed; nothing to print yet.
        case incomplete
        case scalar(UInt32)
        /// One U+FFFD. The byte is consumed.
        case invalid
        /// One U+FFFD, then this scalar, decoded from the same byte.
        case invalidThen(UInt32)
        /// One U+FFFD; the byte began a new, still incomplete sequence.
        case invalidThenIncomplete
    }

    public static let replacement: UInt32 = 0xFFFD

    private var codepoint: UInt32 = 0
    private var bytesNeeded = 0
    private var bytesSeen = 0
    private var lowerBoundary: UInt8 = 0x80
    private var upperBoundary: UInt8 = 0xBF

    public init() {}

    /// True while a multi-byte sequence is part-way through.
    public var isPending: Bool { bytesNeeded > 0 }

    public mutating func decode(_ byte: UInt8) -> Result {
        guard bytesNeeded > 0 else { return start(byte) }

        guard byte >= lowerBoundary, byte <= upperBoundary else {
            // The sequence is malformed. Report it, and give the byte a
            // second chance as the start of the next one.
            reset()
            switch start(byte) {
            case .scalar(let scalar): return .invalidThen(scalar)
            case .incomplete: return .invalidThenIncomplete
            default: return .invalidThen(Self.replacement)
            }
        }

        // Only the first continuation byte has a narrowed range; it is what
        // rejects overlongs, surrogates and values above U+10FFFF.
        lowerBoundary = 0x80
        upperBoundary = 0xBF
        codepoint = codepoint << 6 | UInt32(byte & 0x3F)
        bytesSeen += 1
        guard bytesSeen == bytesNeeded else { return .incomplete }

        let scalar = codepoint
        reset()
        return .scalar(scalar)
    }

    /// Ends the stream. Returns true if a partial sequence was dropped, in
    /// which case the caller prints one U+FFFD.
    public mutating func flush() -> Bool {
        guard bytesNeeded > 0 else { return false }
        reset()
        return true
    }

    private mutating func start(_ byte: UInt8) -> Result {
        switch byte {
        case 0x00...0x7F:
            return .scalar(UInt32(byte))
        case 0xC2...0xDF:
            begin(byte & 0x1F, needed: 1)
        case 0xE0...0xEF:
            begin(byte & 0x0F, needed: 2)
            if byte == 0xE0 { lowerBoundary = 0xA0 }  // no overlong two-byte
            if byte == 0xED { upperBoundary = 0x9F }  // no surrogates
        case 0xF0...0xF4:
            begin(byte & 0x07, needed: 3)
            if byte == 0xF0 { lowerBoundary = 0x90 }  // no overlong three-byte
            if byte == 0xF4 { upperBoundary = 0x8F }  // nothing above U+10FFFF
        default:
            // 0x80–0xBF is a continuation byte with nothing to continue —
            // which is also how a lone C1 control arrives in a UTF-8 stream.
            // 0xC0, 0xC1 are overlong two-byte leads; 0xF5–0xFF are out of
            // range. None of them can begin a character.
            return .invalid
        }
        return .incomplete
    }

    private mutating func begin(_ bits: UInt8, needed: Int) {
        codepoint = UInt32(bits)
        bytesNeeded = needed
        bytesSeen = 0
        lowerBoundary = 0x80
        upperBoundary = 0xBF
    }

    private mutating func reset() {
        codepoint = 0
        bytesNeeded = 0
        bytesSeen = 0
        lowerBoundary = 0x80
        upperBoundary = 0xBF
    }
}
