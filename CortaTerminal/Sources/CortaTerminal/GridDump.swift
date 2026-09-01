/// Serialising a grid to text, for golden-file tests (`CONFORMANCE.md` §4.1)
/// and for `corta-dump`.
///
/// The format is designed to be *written by hand* and diffed by eye. Every
/// row is padded to the full width and delimited, so an expectation file has
/// no significant trailing whitespace and a one-column drift is visible as a
/// misaligned `|`. Styles go in a parallel layer with a legend rather than
/// inline, so the character layer stays readable.
///
/// This is not a hot path: it allocates freely and works in `String`.
extension Grid {
    /// A plain-text rendering of the grid.
    ///
    ///     rows: 3 columns: 10
    ///     cursor: row 1 column 3
    ///        0 |hello     |
    ///        1 |wor       | wrapped
    ///        2 |          |
    ///     styles:
    ///        0 |AAAAA.....|
    ///        1 |..........|
    ///        2 |..........|
    ///        A = fg:1 bg:default attrs:bold
    public func dump() -> String {
        var styles = StyleLegend()
        var text = ""

        text += "rows: \(rows) columns: \(columns)\n"
        text += "cursor: row \(cursor.row) column \(cursor.column)"
        text += pendingWrap ? " wrap-pending\n" : "\n"

        for row in 0..<rows {
            text += Self.characterRow(lines[row], number: row, columns: columns)
        }

        for row in 0..<rows { styles.scan(lines[row], columns: columns) }

        if !styles.isEmpty {
            text += "styles:\n"
            for row in 0..<rows {
                text += styles.row(lines[row], number: row, columns: columns)
            }
            text += styles.description
        }
        return text
    }

    private static func characterRow(_ line: Line, number: Int, columns: Int) -> String {
        var text = rowNumber(number) + " |"
        for column in 0..<columns {
            text.unicodeScalars.append(displayScalar(line[column]))
        }
        text += "|"
        text += line.wrapped ? " wrapped\n" : "\n"
        return text
    }

    fileprivate static func rowNumber(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: " ", count: max(0, 4 - digits.count)) + digits
    }

    /// What a cell looks like in the character layer. Control scalars cannot
    /// reach the grid, but a corrupt one must not produce an unreadable dump.
    private static func displayScalar(_ cell: Cell) -> Unicode.Scalar {
        guard let scalar = Unicode.Scalar(cell.scalar) else { return "\u{FFFD}" }
        switch scalar.value {
        case 0x00..<0x20, 0x7F..<0xA0: return "\u{FFFD}"
        default: return scalar
        }
    }
}

/// Assigns a letter to each distinct rendition in a grid, in order of first
/// appearance, so the style layer is a single character per cell.
private struct StyleLegend {
    /// Enough symbols for any dump worth reading by hand; beyond that the
    /// layer stops being useful anyway and every further style is `?`.
    private static let symbols = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    private var order: [Cell] = []

    var isEmpty: Bool { order.isEmpty }

    /// Renditions compare equal regardless of which character carries them.
    private static func rendition(_ cell: Cell) -> Cell {
        Cell(
            foreground: cell.foreground,
            background: cell.background,
            attributes: cell.attributes
        )
    }

    private static func isDefault(_ cell: Cell) -> Bool {
        rendition(cell) == Cell.blank
    }

    mutating func scan(_ line: Line, columns: Int) {
        for column in 0..<columns {
            let cell = line[column]
            guard !Self.isDefault(cell) else { continue }
            let style = Self.rendition(cell)
            if !order.contains(style) { order.append(style) }
        }
    }

    private func symbol(for cell: Cell) -> Character {
        guard !Self.isDefault(cell) else { return "." }
        guard let index = order.firstIndex(of: Self.rendition(cell)),
            index < Self.symbols.count
        else { return "?" }
        return Self.symbols[index]
    }

    func row(_ line: Line, number: Int, columns: Int) -> String {
        var text = Grid.rowNumber(number) + " |"
        for column in 0..<columns {
            text.append(symbol(for: line[column]))
        }
        return text + "|\n"
    }

    var description: String {
        var text = ""
        for (index, style) in order.enumerated() {
            let symbol = index < Self.symbols.count ? Self.symbols[index] : "?"
            text += "   \(symbol) = fg:\(Self.name(style.foreground))"
            text += " bg:\(Self.name(style.background))"
            text += " attrs:\(Self.name(style.attributes))\n"
        }
        return text
    }

    private static func name(_ color: Color) -> String {
        if let index = color.index { return String(index) }
        if let rgb = color.components { return "rgb(\(rgb.red),\(rgb.green),\(rgb.blue))" }
        return "default"
    }

    private static func name(_ attributes: CellAttributes) -> String {
        let all: [(CellAttributes, String)] = [
            (.bold, "bold"), (.dim, "dim"), (.italic, "italic"),
            (.underline, "underline"), (.blink, "blink"), (.reverse, "reverse"),
            (.invisible, "invisible"), (.strikethrough, "strikethrough"),
        ]
        let names = all.filter { attributes.contains($0.0) }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}
