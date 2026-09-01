/// The non-colour rendition flags of a cell.
///
/// A `UInt16` bitfield rather than a set of `Bool`s: it keeps `Cell` at 16
/// bytes and makes "is this cell styled at all" a single comparison.
public struct CellAttributes: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let dim = CellAttributes(rawValue: 1 << 1)
    public static let italic = CellAttributes(rawValue: 1 << 2)
    public static let underline = CellAttributes(rawValue: 1 << 3)
    public static let blink = CellAttributes(rawValue: 1 << 4)
    public static let reverse = CellAttributes(rawValue: 1 << 5)
    public static let invisible = CellAttributes(rawValue: 1 << 6)
    public static let strikethrough = CellAttributes(rawValue: 1 << 7)

    /// M2.1 width flags. These are structural, not rendition: SGR never sets
    /// them, the grid sets them as it writes, and the dump's style layer
    /// masks them out.
    ///
    /// The lead cell of a double-width pair (`wcwidth`/xterm convention: a
    /// wide scalar occupies two columns).
    public static let wide = CellAttributes(rawValue: 1 << 8)
    /// The second cell of a double-width pair. Distinguishable from a real
    /// blank so erase and editing operations can keep pairs consistent —
    /// touching either half blanks both.
    public static let wideSpacer = CellAttributes(rawValue: 1 << 9)

    /// Bits 10–15 remain reserved.
}
