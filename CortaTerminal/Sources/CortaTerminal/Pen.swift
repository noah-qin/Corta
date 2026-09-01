/// The current graphic rendition — what SGR sets and what newly written
/// cells inherit.
public struct Pen: Equatable, Sendable {
    public var foreground: Color
    public var background: Color
    public var attributes: CellAttributes

    public init(
        foreground: Color = .default,
        background: Color = .default,
        attributes: CellAttributes = []
    ) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    /// SGR 0.
    public mutating func reset() {
        self = Pen()
    }

    /// A cell carrying `scalar` in the current rendition.
    @inline(__always)
    public func cell(_ scalar: UInt32) -> Cell {
        Cell(
            scalar: scalar,
            foreground: foreground,
            background: background,
            attributes: attributes
        )
    }

    /// What an erase writes.
    ///
    /// Background colour erase (BCE, as in xterm): an erased cell takes the
    /// current background but not the current foreground or attributes —
    /// there is no character to draw, so underlining or colouring it would
    /// invent ink the program did not ask for.
    @inline(__always)
    public var eraseCell: Cell {
        Cell(background: background)
    }
}
