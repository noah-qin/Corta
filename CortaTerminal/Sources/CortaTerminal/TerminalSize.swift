import Darwin

/// The size of a terminal, in character cells and (optionally) pixels.
///
/// Pixel dimensions are reported to the child through `TIOCSWINSZ`; some
/// programs use them for sixel and image protocols. Corta does not
/// implement those yet, so zero is a truthful answer.
public struct TerminalSize: Equatable, Sendable {
    public var rows: UInt16
    public var columns: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    public init(
        rows: UInt16 = 24,
        columns: UInt16 = 80,
        pixelWidth: UInt16 = 0,
        pixelHeight: UInt16 = 0
    ) {
        self.rows = rows
        self.columns = columns
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// A `struct winsize` carrying the same dimensions.
    var winsize: Darwin.winsize {
        Darwin.winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: pixelWidth,
            ws_ypixel: pixelHeight
        )
    }

    init(_ ws: Darwin.winsize) {
        self.init(
            rows: ws.ws_row,
            columns: ws.ws_col,
            pixelWidth: ws.ws_xpixel,
            pixelHeight: ws.ws_ypixel
        )
    }
}
