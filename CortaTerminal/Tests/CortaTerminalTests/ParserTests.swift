import Testing

@testable import CortaTerminal

/// Records what the parser recognised, so a byte stream can be compared
/// against an expected action sequence.
struct RecordingPerformer: ParserPerformer {
    enum Action: Equatable {
        case print(UInt32)
        case execute(UInt8)
        case escape(Intermediates, UInt8)
        case csi(CSISequence)
        case osc([UInt8])
    }

    var actions: [Action] = []

    mutating func print(_ scalar: UInt32) { actions.append(.print(scalar)) }
    mutating func execute(_ control: UInt8) { actions.append(.execute(control)) }

    mutating func escapeDispatch(intermediates: Intermediates, final: UInt8) {
        actions.append(.escape(intermediates, final))
    }

    mutating func csiDispatch(_ sequence: CSISequence) { actions.append(.csi(sequence)) }
    mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) { actions.append(.osc(Array(bytes))) }
}

/// M1.8 and M1.9 — the VT500 state machine and its parameter caps.
///
/// The expectations follow Paul Williams' parser diagram
/// (<https://vt100.net/emu/dec_ansi_parser>) and ECMA-48 §5.4, which defines
/// a control sequence as CSI, parameter bytes 0x30–0x3F, intermediate bytes
/// 0x20–0x2F, and one final byte 0x40–0x7E.
@Suite("Parser")
struct ParserTests {
    /// Parses an escape-encoded stream (`\e`, `\x1b`, …) into actions.
    private func actions(_ source: String) throws -> [RecordingPerformer.Action] {
        var parser = Parser()
        var performer = RecordingPerformer()
        parser.parse(try Golden.decode(source), performer: &performer)
        return performer.actions
    }

    private func printed(_ actions: [RecordingPerformer.Action]) -> String {
        var text = ""
        for action in actions {
            if case .print(let scalar) = action, let unicode = Unicode.Scalar(scalar) {
                text.unicodeScalars.append(unicode)
            }
        }
        return text
    }

    // MARK: - Ground

    @Test("printable bytes print and C0 controls execute")
    func groundState() throws {
        #expect(
            try actions("ab\\r\\n") == [
                .print(0x61), .print(0x62), .execute(0x0D), .execute(0x0A),
            ])
    }

    @Test("UTF-8 is decoded in the ground state")
    func groundDecodesUTF8() throws {
        // U+4F60 你 as E4 BD A0.
        #expect(try actions("\\xe4\\xbd\\xa0") == [.print(0x4F60)])
    }

    // MARK: - CSI

    @Test("a CSI sequence dispatches its parameters and final byte")
    func csiParameters() throws {
        #expect(
            try actions("\\e[1;2H")
                == [.csi(CSISequence(parameters: Parameters([1, 2]), final: 0x48))])
    }

    /// ECMA-48 §5.4.2: an omitted parameter is empty, and the sequence's
    /// default applies. `CSI H` has no parameters at all.
    @Test("omitted parameters are counted but empty")
    func omittedParameters() throws {
        #expect(try actions("\\e[H") == [.csi(CSISequence(final: 0x48))])

        let semicolonFirst = try actions("\\e[;5H")
        #expect(semicolonFirst == [.csi(CSISequence(parameters: Parameters([0, 5]), final: 0x48))])
        guard case .csi(let sequence) = semicolonFirst[0] else { return }
        #expect(sequence.parameters.count == 2)
        #expect(sequence.parameters[0] == 0)
        #expect(sequence.parameters.value(0, default: 1) == 1)
        #expect(sequence.parameters.value(1, default: 1) == 5)
    }

    @Test("a private marker is kept apart from the parameters")
    func privateMarkers() throws {
        #expect(
            try actions("\\e[?1049h")
                == [
                    .csi(
                        CSISequence(
                            parameters: Parameters([1049]), privateMarker: 0x3F, final: 0x68))
                ])
        #expect(try actions("\\e[>c") == [.csi(CSISequence(privateMarker: 0x3E, final: 0x63))])
    }

    @Test("intermediates are collected")
    func csiIntermediates() throws {
        #expect(
            try actions("\\e[2$p")
                == [
                    .csi(
                        CSISequence(
                            parameters: Parameters([2]),
                            intermediates: Intermediates([0x24]),
                            final: 0x70))
                ])
    }

    /// Sub-parameters are P2. Until they exist, the whole sequence is
    /// ignored rather than half-read — and the stream resynchronises on the
    /// final byte, so the text after it still prints.
    @Test("a colon sends the sequence to the ignore state")
    func colonIsIgnored() throws {
        let result = try actions("\\e[38:2:1:2:3mX")
        #expect(result == [.print(0x58)])
    }

    /// Williams' diagram: C0 controls inside a sequence are executed where
    /// they appear, and the sequence continues.
    @Test("a control byte inside a sequence executes without breaking it")
    func controlsInsideSequences() throws {
        #expect(
            try actions("\\e[3\\rm")
                == [.execute(0x0D), .csi(CSISequence(parameters: Parameters([3]), final: 0x6D))])
    }

    /// CAN and SUB abort the sequence in progress from any state. Without
    /// them a malformed sequence would capture every byte after it.
    @Test("CAN aborts a sequence in progress")
    func cancelAbortsASequence() throws {
        #expect(try actions("\\e[1\\x182") == [.execute(0x18), .print(0x32)])
    }

    @Test("ESC restarts a sequence in progress")
    func escapeRestartsASequence() throws {
        #expect(
            try actions("\\e[1\\e[2H")
                == [.csi(CSISequence(parameters: Parameters([2]), final: 0x48))])
    }

    @Test("an unknown final byte is dispatched, not printed")
    func unknownSequencesAreNotPrinted() throws {
        let result = try actions("\\e[1~X")
        #expect(result.count == 2)
        #expect(printed(result) == "X")
    }

    // MARK: - ESC and strings

    @Test("an escape sequence dispatches its intermediates and final")
    func escapeSequences() throws {
        #expect(try actions("\\e(B") == [.escape(Intermediates([0x28]), 0x42)])
        #expect(try actions("\\eM") == [.escape(Intermediates(), 0x4D)])
    }

    @Test("an OSC string ends at BEL or at ST")
    func oscTermination() throws {
        #expect(try actions("\\e]0;title\\a") == [.osc(Array("0;title".utf8))])
        // ESC \ — the C1 string terminator in its seven-bit form.
        #expect(
            try actions("\\e]0;x\\e\\\\")
                == [.osc(Array("0;x".utf8)), .escape(Intermediates(), 0x5C)])
    }

    @Test("a DCS payload is consumed, not printed")
    func dcsIsConsumed() throws {
        #expect(try actions("\\eP1$r0m\\e\\\\A") == [.escape(Intermediates(), 0x5C), .print(0x41)])
    }

    @Test("APC and PM strings are consumed")
    func apcIsConsumed() throws {
        #expect(try actions("\\e_hello\\e\\\\A") == [.escape(Intermediates(), 0x5C), .print(0x41)])
    }

    // MARK: - Caps (SECURITY.md §3)

    /// The stream is hostile. 10,000 parameters must cost the same bounded
    /// memory as two, and the sequence still dispatches with the first 16.
    @Test("a flood of parameters is bounded and still dispatches")
    func parameterCountIsCapped() throws {
        let flood = "\\e[" + String(repeating: "1;", count: 10_000) + "m"
        let result = try actions(flood)
        #expect(result.count == 1)
        guard case .csi(let sequence) = result[0] else {
            Issue.record("expected one CSI dispatch")
            return
        }
        #expect(sequence.final == 0x6D)
        #expect(sequence.parameters.count == Parameters.maxCount)
        #expect(sequence.parameters.didOverflow)
        #expect(sequence.parameters[0] == 1)
        #expect(sequence.parameters[15] == 1)
        // The parameter list is a fixed-size value, whatever it was fed.
        #expect(MemoryLayout<Parameters>.size <= 48)
    }

    @Test("a parameter value saturates instead of wrapping")
    func parameterValueIsClamped() throws {
        let result = try actions("\\e[99999999999999999999H")
        #expect(
            result == [.csi(CSISequence(parameters: Parameters([Parameters.maxValue]), final: 0x48))]
        )
    }

    @Test("more intermediates than a sequence can hold ignores the sequence")
    func intermediateCountIsCapped() throws {
        #expect(try actions("\\e[!\\x22#pX") == [.print(0x58)])
    }

    /// The canonical exhaustion case: a stream that opens an OSC and never
    /// closes it must not accumulate. The sequence is discarded rather than
    /// truncated — a half-read title is worse than none — and the parser
    /// resynchronises on the terminator.
    @Test("an oversized OSC string is discarded and the stream resynchronises")
    func oscLengthIsCapped() throws {
        let payload = String(repeating: "A", count: Parser.maxStringLength + 1000)
        let result = try actions("\\e]0;" + payload + "\\aX")
        #expect(result == [.print(0x58)])
    }

    @Test("an unterminated OSC never dispatches and never grows")
    func unterminatedOSCIsBounded() throws {
        var parser = Parser()
        var performer = RecordingPerformer()
        parser.parse(Array("\u{1B}]0;".utf8), performer: &performer)
        for _ in 0..<64 {
            parser.parse(Array(repeating: UInt8(ascii: "A"), count: 16_384), performer: &performer)
        }
        #expect(performer.actions.isEmpty)
        #expect(parser.state == .oscIgnore)

        // And it recovers: BEL ends it, and the next text prints.
        parser.parse(Array("\u{07}X".utf8), performer: &performer)
        #expect(performer.actions == [.print(0x58)])
    }

    /// Nothing in a byte stream may trap. Every byte in every state.
    @Test("no byte stream traps the parser")
    func parsingIsTotal() {
        var parser = Parser()
        var performer = RecordingPerformer()
        var generator: UInt64 = 0x2545_F491_4F6C_DD1D
        var bytes: [UInt8] = []
        bytes.reserveCapacity(200_000)
        for _ in 0..<200_000 {
            generator ^= generator << 13
            generator ^= generator >> 7
            generator ^= generator << 17
            bytes.append(UInt8(truncatingIfNeeded: generator))
        }
        parser.parse(bytes, performer: &performer)
        #expect(!performer.actions.isEmpty)
    }
}
