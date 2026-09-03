/// One character cell.
///
/// Fixed size, `Equatable`, no reference fields: a row is a
/// `ContiguousArray<Cell>` that the renderer can walk without an ARC traffic
/// jam (`PERFORMANCE.md` §3, `DESIGN.md` §2.3).
///
/// The layout is deliberate — 4 + 4 + 4 + 2 + 2 = 16 bytes, asserted by
/// `CellLayoutTests`. Growing it is a real cost: a 200×100k scrollback is
/// 16 bytes × every cell that is actually stored.
///
/// That budget is why the OSC 8 hyperlink id (M6.8) is not a field of its
/// own. Unicode's codespace ends at U+10FFFF, so a scalar needs 21 of the
/// 32 bits `scalar` was already spending; the hyperlink id lives in the 11
/// left over. The cost is that `scalar` becomes a computed property over the
/// packed word — which is a mask and a shift, and measurably nothing next to
/// an 18- or 20-byte cell.
public struct Cell: Equatable, Sendable {
    /// `scalar` in the low 21 bits, `hyperlink` in the high 11. Private so
    /// the packing can never be assumed by anything but this type.
    private var packed: UInt32

    private static let scalarBits: UInt32 = 21
    private static let scalarMask: UInt32 = (1 << scalarBits) - 1
    /// Ids above this do not fit; `HyperlinkTable` caps itself to match.
    static let maximumHyperlinkID: UInt16 = UInt16((1 << (32 - scalarBits)) - 1)

    /// The base Unicode scalar. For a cluster that does not fit in one scalar
    /// this is the *base* character and `grapheme` names the full cluster.
    @inline(__always)
    public var scalar: UInt32 {
        get { packed & Self.scalarMask }
        set { packed = (packed & ~Self.scalarMask) | (newValue & Self.scalarMask) }
    }

    /// The OSC 8 hyperlink this cell belongs to (M6.8), or `.none`. A key
    /// into the grid's `HyperlinkTable`, exactly as `grapheme` is a key into
    /// its `GraphemeTable`.
    @inline(__always)
    public var hyperlink: HyperlinkID {
        get { HyperlinkID(rawValue: UInt16(packed >> Self.scalarBits)) }
        set {
            packed =
                (packed & Self.scalarMask) | (UInt32(newValue.rawValue) << Self.scalarBits)
        }
    }

    public var foreground: Color
    public var background: Color
    public var attributes: CellAttributes
    /// A key into the session's `GraphemeTable`, or `.none` for the common
    /// case of a cell that is exactly one scalar (`DESIGN.md` §2.3).
    public var grapheme: GraphemeID

    @inline(__always)
    public init(
        scalar: UInt32 = 0x20,
        foreground: Color = .default,
        background: Color = .default,
        attributes: CellAttributes = [],
        grapheme: GraphemeID = .none,
        hyperlink: HyperlinkID = .none
    ) {
        self.packed =
            (scalar & Self.scalarMask) | (UInt32(hyperlink.rawValue) << Self.scalarBits)
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.grapheme = grapheme
    }

    /// An unwritten cell: a space in the default colours.
    ///
    /// This exact value is what "blank" means everywhere else — trimming a
    /// row, deciding whether an erase can truncate instead of fill. A cell
    /// erased under a non-default background is *not* blank and is stored.
    public static let blank = Cell()

    @inline(__always)
    public var isBlank: Bool { self == Cell.blank }
}
