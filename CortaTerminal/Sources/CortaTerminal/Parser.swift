/// The VT500-series state machine, following Paul Williams' parser diagram
/// (<https://vt100.net/emu/dec_ansi_parser>).
///
/// It knows nothing about the screen. It consumes bytes, decodes UTF-8 in the
/// ground state, and tells a `ParserPerformer` what it recognised.
///
/// The caps in `SECURITY.md` §3 are part of the machine rather than a check
/// bolted on afterwards: parameter count and magnitude in `Parameters`,
/// intermediate count in `Intermediates`, and string length here. An
/// unterminated OSC — a stream that opens one and never closes it — must not
/// accumulate gigabytes, and a sequence that overflows is discarded and the
/// stream resynchronises rather than being half-applied.
public struct Parser: Sendable {
    /// The states of the diagram. DCS is consumed and ignored: device control
    /// strings are P2 (`CONFORMANCE.md` §1.1) and consuming them correctly is
    /// what stops their payload being printed as text.
    public enum State: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        /// An OSC that exceeded `maxStringLength`; consumed to its terminator
        /// and never dispatched.
        case oscIgnore
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsIgnore
        /// SOS and PM strings, consumed and dropped — nothing this project
        /// implements uses either.
        case sosPmString
        /// An APC string, collected for `apcDispatch` (M10: Kitty graphics is
        /// the one user of APC).
        case apcString
        /// An APC string that exceeded `maxAPCStringLength`; consumed to its
        /// terminator and never dispatched.
        case apcIgnore
    }

    /// The hard limit on an OSC payload. Long enough for any real title, URL
    /// or clipboard payload; short enough that a hostile stream cannot use it
    /// as an allocator.
    public static let maxStringLength = 4096

    /// The hard limit on one APC chunk. The Kitty graphics protocol is
    /// designed around chunked transmission specifically so no single
    /// escape sequence has to be arbitrarily long — every reference client
    /// chunks a base64 payload at 4096 bytes and continues with `m=1` — so
    /// this affords a full chunk (4096 bytes of payload) plus generous
    /// headroom for the `key=value,...;` control-data prefix, while still
    /// being a hard, explicit cap (`SECURITY.md` §3): an unterminated APC
    /// string must not accumulate without bound any more than an
    /// unterminated OSC one may.
    public static let maxAPCStringLength = 6144

    public private(set) var state: State = .ground

    private var parameters = Parameters()
    private var intermediates = Intermediates()
    private var privateMarker: UInt8 = 0
    private var stringBuffer: [UInt8] = []
    private var decoder = UTF8Decoder()

    public init() {
        stringBuffer.reserveCapacity(256)
    }

    public mutating func parse<P: ParserPerformer>(
        _ bytes: some Sequence<UInt8>,
        performer: inout P
    ) {
        for byte in bytes { advance(byte, performer: &performer) }
    }

    /// Contiguous input gets an ASCII-run fast path. PTY reads and the
    /// benchmark both arrive as `[UInt8]`, so this is the production path;
    /// the generic overload above remains for streaming/test sequences.
    public mutating func parse<P: ParserPerformer>(
        _ bytes: [UInt8],
        performer: inout P
    ) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if case .ground = state, bytes[index] >= 0x20, bytes[index] < 0x7F {
                var end = index + 1
                while end < bytes.endIndex, bytes[end] >= 0x20, bytes[end] < 0x7F {
                    end += 1
                }
                performer.printASCII(bytes[index..<end])
                index = end
            } else {
                advance(bytes[index], performer: &performer)
                index += 1
            }
        }
    }

    public mutating func advance<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        // "Anywhere" transitions, which outrank the current state. CAN and
        // SUB abort whatever is in progress; ESC restarts it. Without these a
        // malformed sequence would capture every byte after it.
        switch byte {
        case 0x18, 0x1A:
            state = .ground
            performer.execute(byte)
            return
        case 0x1B:
            if state == .oscString { dispatchString(performer: &performer) }
            if state == .apcString { dispatchAPCString(performer: &performer) }
            clear()
            state = .escape
            return
        default:
            break
        }

        switch state {
        case .ground: ground(byte, performer: &performer)
        case .escape: escape(byte, performer: &performer)
        case .escapeIntermediate: escapeIntermediate(byte, performer: &performer)
        case .csiEntry: csiEntry(byte, performer: &performer)
        case .csiParam: csiParam(byte, performer: &performer)
        case .csiIntermediate: csiIntermediate(byte, performer: &performer)
        case .csiIgnore: csiIgnore(byte, performer: &performer)
        case .oscString: oscString(byte, performer: &performer)
        case .oscIgnore: oscIgnore(byte)
        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsIgnore:
            dcs(byte, performer: &performer)
        case .sosPmString:
            break  // Consumed until ESC, handled above.
        case .apcString: apcString(byte)
        case .apcIgnore: apcIgnore(byte)
        }
    }

    // MARK: - States

    private mutating func ground<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x00...0x1F:
            performer.execute(byte)
        case 0x20...0x7F:
            // Including DEL, as the diagram has it. An invisible control
            // byte is what makes an injected sequence readable as ordinary
            // text, so it is drawn rather than dropped (`SECURITY.md` §2.5).
            performer.print(UInt32(byte))
        default:
            // 0x80 and above is UTF-8. A C1 control byte therefore arrives
            // as malformed UTF-8 and prints as U+FFFD, which is deliberate:
            // an invisible control byte is what makes an injection readable
            // as ordinary text (`SECURITY.md` §2.5).
            switch decoder.decode(byte) {
            case .incomplete:
                break
            case .scalar(let scalar):
                performer.print(scalar)
            case .invalid, .invalidThenIncomplete:
                performer.print(UTF8Decoder.replacement)
            case .invalidThen(let scalar):
                performer.print(UTF8Decoder.replacement)
                performer.print(scalar)
            }
        }
    }

    private mutating func escape<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x20...0x2F:
            collectIntermediate(byte)
            if state == .escape { state = .escapeIntermediate }
        case 0x50:  // ESC P — DCS
            state = .dcsEntry
        case 0x58, 0x5E:  // ESC X / ESC ^ — SOS, PM: consumed and dropped.
            state = .sosPmString
        case 0x5F:  // ESC _ — APC (M10: Kitty graphics)
            stringBuffer.removeAll(keepingCapacity: true)
            state = .apcString
        case 0x5B:  // ESC [ — CSI
            state = .csiEntry
        case 0x5D:  // ESC ] — OSC
            stringBuffer.removeAll(keepingCapacity: true)
            state = .oscString
        case 0x7F:
            break  // DEL is ignored inside a sequence.
        default:
            performer.escapeDispatch(intermediates: intermediates, final: byte)
            state = .ground
        }
    }

    private mutating func escapeIntermediate<P: ParserPerformer>(
        _ byte: UInt8, performer: inout P
    ) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x20...0x2F:
            collectIntermediate(byte)
        case 0x7F:
            break
        default:
            performer.escapeDispatch(intermediates: intermediates, final: byte)
            state = .ground
        }
    }

    private mutating func csiEntry<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x20...0x2F:
            collectIntermediate(byte)
            if state == .csiEntry { state = .csiIntermediate }
        case 0x30...0x39:
            parameters.accumulate(byte - UInt8(ascii: "0"))
            state = .csiParam
        case 0x3B:
            parameters.separate()
            state = .csiParam
        case 0x3A:
            // Sub-parameters (`SGR 38:2::r:g:b`) are P2; ignoring the whole
            // sequence is the safe reading until M2 implements them.
            state = .csiIgnore
        case 0x3C...0x3F:
            privateMarker = byte
            state = .csiParam
        case 0x7F:
            break
        default:
            dispatchCSI(final: byte, performer: &performer)
        }
    }

    private mutating func csiParam<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x30...0x39:
            parameters.accumulate(byte - UInt8(ascii: "0"))
        case 0x3B:
            parameters.separate()
        case 0x20...0x2F:
            collectIntermediate(byte)
            if state == .csiParam { state = .csiIntermediate }
        case 0x3A, 0x3C...0x3F:
            state = .csiIgnore
        case 0x7F:
            break
        default:
            dispatchCSI(final: byte, performer: &performer)
        }
    }

    private mutating func csiIntermediate<P: ParserPerformer>(
        _ byte: UInt8, performer: inout P
    ) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x20...0x2F:
            collectIntermediate(byte)
        case 0x30...0x3F:
            state = .csiIgnore
        case 0x7F:
            break
        default:
            dispatchCSI(final: byte, performer: &performer)
        }
    }

    private mutating func csiIgnore<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            performer.execute(byte)
        case 0x40...0x7E:
            state = .ground
        default:
            break
        }
    }

    private mutating func oscString<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch byte {
        case 0x07:  // BEL, xterm's terminator.
            dispatchString(performer: &performer)
            state = .ground
        case 0x00...0x06, 0x08...0x1F:
            break  // Controls inside a string are dropped, not executed.
        default:
            guard stringBuffer.count < Self.maxStringLength else {
                // Discard the whole sequence rather than a truncated one: a
                // half-applied title or clipboard payload is worse than none.
                stringBuffer.removeAll(keepingCapacity: true)
                state = .oscIgnore
                return
            }
            stringBuffer.append(byte)
        }
    }

    private mutating func oscIgnore(_ byte: UInt8) {
        if byte == 0x07 { state = .ground }
    }

    /// Collects an APC string's payload — see `maxAPCStringLength`'s doc
    /// comment for the cap. APC's only terminator is ST (`ESC \`), unlike
    /// OSC's BEL-or-ST, so unlike `oscString` there is no in-state
    /// terminator byte to watch for here: ESC always outranks this state
    /// (the "anywhere" handling in `advance`), which dispatches and clears
    /// before this is ever reached again.
    private mutating func apcString(_ byte: UInt8) {
        switch byte {
        case 0x00...0x1F:
            break  // Controls inside a string are dropped, not executed.
        default:
            guard stringBuffer.count < Self.maxAPCStringLength else {
                // Discard the whole sequence rather than a truncated one —
                // same reasoning as `oscString`'s overflow: a half-decoded
                // image is worse than none.
                stringBuffer.removeAll(keepingCapacity: true)
                state = .apcIgnore
                return
            }
            stringBuffer.append(byte)
        }
    }

    /// An overflowed APC string's remaining bytes: discarded, same as
    /// `oscIgnore`, until the "anywhere" ESC handling in `advance` ends it.
    private mutating func apcIgnore(_ byte: UInt8) {}

    /// DCS is recognised so that its payload is consumed rather than printed.
    /// Nothing is dispatched; device control strings are P2.
    private mutating func dcs<P: ParserPerformer>(_ byte: UInt8, performer: inout P) {
        switch state {
        case .dcsEntry, .dcsParam, .dcsIntermediate:
            switch byte {
            case 0x30...0x39, 0x3B:
                state = .dcsParam
            case 0x20...0x2F:
                state = .dcsIntermediate
            case 0x40...0x7E:
                state = .dcsIgnore  // The payload runs until ST.
            default:
                break
            }
        default:
            break  // Payload bytes; dropped. ESC returns to the escape state.
        }
    }

    // MARK: - Helpers

    private mutating func collectIntermediate(_ byte: UInt8) {
        guard intermediates.collect(byte) else {
            // More intermediates than any real sequence has. Consume the
            // rest of it rather than printing its final byte as text.
            state = .csiIgnore
            return
        }
    }

    private mutating func dispatchCSI<P: ParserPerformer>(final: UInt8, performer: inout P) {
        performer.csiDispatch(
            CSISequence(
                parameters: parameters,
                intermediates: intermediates,
                privateMarker: privateMarker,
                final: final
            )
        )
        state = .ground
        clear()
    }

    private mutating func dispatchString<P: ParserPerformer>(performer: inout P) {
        performer.oscDispatch(stringBuffer[...])
        stringBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func dispatchAPCString<P: ParserPerformer>(performer: inout P) {
        performer.apcDispatch(stringBuffer[...])
        stringBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func clear() {
        parameters.reset()
        intermediates.reset()
        privateMarker = 0
    }
}
