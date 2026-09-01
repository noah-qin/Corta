/// The numeric parameters of a CSI sequence.
///
/// Fixed capacity and no heap storage: a parameter list is a value the parser
/// hands to the performer, and the parse path allocates nothing
/// (`PERFORMANCE.md` §3).
///
/// Both caps are from `SECURITY.md` §3. The stream that supplies them is
/// hostile, and `CSI 1;1;1;…;1 m` with a million parameters must cost a
/// bounded amount of memory and a bounded amount of time.
public struct Parameters: Equatable, Sendable {
    /// xterm's limit. Parameters beyond it are ignored, and the sequence is
    /// still dispatched with the ones that fit.
    public static let maxCount = 16

    /// Values saturate here rather than wrapping. A clamped parameter is
    /// clamped again against the screen by whoever uses it.
    public static let maxValue: UInt16 = 65535

    private var values = InlineArray<16, UInt16>(repeating: 0)

    /// How many parameters were written, including omitted ones — `CSI ;5H`
    /// has two.
    public private(set) var count = 0

    /// True once a sequence tried to supply more than `maxCount`.
    public private(set) var didOverflow = false

    public init() {}

    public init(_ values: [UInt16]) {
        for (index, value) in values.enumerated() {
            if index > 0 { separate() }
            for digit in String(value).utf8 {
                accumulate(digit - UInt8(ascii: "0"))
            }
            // A literal zero has no digits that change the slot, but it must
            // still count as a written parameter.
            if count == 0 { count = 1 }
        }
    }

    public subscript(index: Int) -> UInt16 {
        guard index >= 0, index < count, index < Self.maxCount else { return 0 }
        return values[index]
    }

    /// A parameter, with the sequence's default substituted where it was
    /// omitted or written as zero — which for almost every CSI sequence is
    /// what a zero means.
    public func value(_ index: Int, default fallback: Int) -> Int {
        let raw = self[index]
        return raw == 0 ? fallback : Int(raw)
    }

    // MARK: - Parsing

    mutating func accumulate(_ digit: UInt8) {
        guard !didOverflow else { return }
        if count == 0 { count = 1 }
        let index = count - 1
        let value = UInt32(values[index]) * 10 + UInt32(digit)
        values[index] = value > UInt32(Self.maxValue) ? Self.maxValue : UInt16(value)
    }

    mutating func separate() {
        guard !didOverflow else { return }
        if count == 0 { count = 1 }
        guard count < Self.maxCount else {
            didOverflow = true
            return
        }
        count += 1
        values[count - 1] = 0
    }

    mutating func reset() {
        self = Parameters()
    }

    public static func == (lhs: Parameters, rhs: Parameters) -> Bool {
        guard lhs.count == rhs.count, lhs.didOverflow == rhs.didOverflow else { return false }
        for index in 0..<min(lhs.count, maxCount) where lhs.values[index] != rhs.values[index] {
            return false
        }
        return true
    }
}

/// The intermediate bytes (0x20–0x2F) of an escape or CSI sequence — the
/// `$` of `CSI $ p`, the `(` of `ESC ( B`.
///
/// Two is xterm's limit; a third sends the sequence to the ignore state,
/// which is the safe reading of an unknown sequence (`SECURITY.md` §3).
public struct Intermediates: Equatable, Sendable {
    public static let maxCount = 2

    public private(set) var first: UInt8 = 0
    public private(set) var second: UInt8 = 0
    public private(set) var count = 0

    public init() {}

    public init(_ bytes: [UInt8]) {
        for byte in bytes { _ = collect(byte) }
    }

    public subscript(index: Int) -> UInt8 {
        switch index {
        case 0 where count > 0: return first
        case 1 where count > 1: return second
        default: return 0
        }
    }

    /// Returns false when the sequence has more intermediates than can be
    /// held, and must therefore be ignored.
    mutating func collect(_ byte: UInt8) -> Bool {
        switch count {
        case 0: first = byte
        case 1: second = byte
        default: return false
        }
        count += 1
        return true
    }

    mutating func reset() {
        self = Intermediates()
    }
}

/// A parsed CSI sequence, as handed to the performer.
public struct CSISequence: Equatable, Sendable {
    public var parameters: Parameters
    public var intermediates: Intermediates
    /// The private-marker byte (0x3C–0x3F): `?` in `CSI ? 1049 h`, `>` in
    /// `CSI > c`. Zero when the sequence has none.
    public var privateMarker: UInt8
    /// The final byte (0x40–0x7E) that names the sequence.
    public var final: UInt8

    public init(
        parameters: Parameters = Parameters(),
        intermediates: Intermediates = Intermediates(),
        privateMarker: UInt8 = 0,
        final: UInt8
    ) {
        self.parameters = parameters
        self.intermediates = intermediates
        self.privateMarker = privateMarker
        self.final = final
    }
}
