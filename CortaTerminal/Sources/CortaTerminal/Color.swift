/// A cell colour: the terminal default, a palette index, or a direct RGB
/// triple.
///
/// Packed into a single `UInt32` so that a `Cell` stays 16 bytes and can be
/// copied without touching the allocator (`PERFORMANCE.md` §3). The high byte
/// is the kind tag; the low 24 bits are the payload.
public struct Color: Equatable, Hashable, Sendable {
    public var rawValue: UInt32

    @inline(__always)
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    private enum Kind: UInt32 {
        case `default` = 0
        case indexed = 1
        case rgb = 2
    }

    private static let kindShift: UInt32 = 24
    private static let payloadMask: UInt32 = 0x00ff_ffff

    /// Whatever the renderer considers the default foreground or background.
    /// Kept distinct from palette entry 0 or 7 so a theme can style it.
    public static let `default` = Color(rawValue: Kind.default.rawValue << kindShift)

    /// A palette entry: 0–7 ANSI, 8–15 bright, 16–255 the xterm cube and
    /// greyscale ramp.
    @inline(__always)
    public static func indexed(_ index: UInt8) -> Color {
        Color(rawValue: Kind.indexed.rawValue << kindShift | UInt32(index))
    }

    @inline(__always)
    public static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Color {
        let payload = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        return Color(rawValue: Kind.rgb.rawValue << kindShift | payload)
    }

    public var isDefault: Bool { rawValue >> Self.kindShift == Kind.default.rawValue }

    /// The palette index, or `nil` if this is not an indexed colour.
    public var index: UInt8? {
        guard rawValue >> Self.kindShift == Kind.indexed.rawValue else { return nil }
        return UInt8(truncatingIfNeeded: rawValue)
    }

    /// The RGB components, or `nil` if this is not a direct colour.
    public var components: (red: UInt8, green: UInt8, blue: UInt8)? {
        guard rawValue >> Self.kindShift == Kind.rgb.rawValue else { return nil }
        let payload = rawValue & Self.payloadMask
        return (
            UInt8(truncatingIfNeeded: payload >> 16),
            UInt8(truncatingIfNeeded: payload >> 8),
            UInt8(truncatingIfNeeded: payload)
        )
    }
}

extension Color {
    // The eight ANSI colours, by name, for readable call sites in tests and
    // in the performer. Bright variants are these plus eight.
    public static let black = Color.indexed(0)
    public static let red = Color.indexed(1)
    public static let green = Color.indexed(2)
    public static let yellow = Color.indexed(3)
    public static let blue = Color.indexed(4)
    public static let magenta = Color.indexed(5)
    public static let cyan = Color.indexed(6)
    public static let white = Color.indexed(7)
}
