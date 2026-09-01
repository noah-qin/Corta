/// One character cell.
///
/// Fixed size, `Equatable`, no reference fields: a row is a
/// `ContiguousArray<Cell>` that the renderer can walk without an ARC traffic
/// jam (`PERFORMANCE.md` §3, `DESIGN.md` §2.3).
///
/// The layout is deliberate — 4 + 4 + 4 + 2 + 2 = 16 bytes, asserted by
/// `CellLayoutTests`. Growing it is a real cost: a 200×100k scrollback is
/// 16 bytes × every cell that is actually stored.
public struct Cell: Equatable, Sendable {
    /// The base Unicode scalar. For a cluster that does not fit in one scalar
    /// this is the *base* character and `grapheme` names the full cluster.
    public var scalar: UInt32
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
        grapheme: GraphemeID = .none
    ) {
        self.scalar = scalar
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
