/// M7.2 — addressing rows that may be on screen or in history, and the
/// shell-integration marks written through that address.
///
/// A command's prompt row is written when the command starts and its exit
/// status arrives when the command ends, which for anything slow is several
/// screenfuls later. Screen rows cannot express that: the row has scrolled
/// into history by then and its index means something else. An *absolute*
/// row — `scrollback.totalPushed + screenRow` — never changes for the life of
/// the line, which is the same reason a selection is anchored against
/// `totalPushed` (M6.10).
extension Grid {
    /// The absolute index of a screen row. Stable: output that scrolls the
    /// row into history does not change it.
    public func absoluteRow(ofScreenRow row: Int) -> Int {
        scrollback.totalPushed + row
    }

    /// The screen row an absolute index names, or `nil` when it has scrolled
    /// off the live screen.
    public func screenRow(ofAbsoluteRow absolute: Int) -> Int? {
        let row = absolute - scrollback.totalPushed
        return row >= 0 && row < rows ? row : nil
    }

    /// The line an absolute index names, on screen or in history. `nil` once
    /// the line has been evicted from the scrollback.
    public func line(atAbsoluteRow absolute: Int) -> Line? {
        let row = absolute - scrollback.totalPushed
        if row >= 0 { return row < rows ? line(row) : nil }
        let index = scrollback.count + row
        return index >= 0 ? scrollback[index] : nil
    }

    public mutating func setMark(_ mark: LineMark, atAbsoluteRow absolute: Int) {
        let row = absolute - scrollback.totalPushed
        if row >= 0 {
            guard row < rows else { return }
            lines[row].mark = mark
        } else {
            scrollback.setMark(mark, at: scrollback.count + row)
        }
    }

    /// Every prompt row in the document, oldest first, as absolute indices.
    ///
    /// Walked rather than maintained as an index: a list would have to be
    /// fixed up by eviction, reflow, `resize` and the alternate-screen swap,
    /// and the walk costs one pass over lines that are already in memory —
    /// paid once per ⌘↑, not per frame.
    public var promptRows: [Int] {
        var rows: [Int] = []
        let base = scrollback.totalPushed - scrollback.count
        for index in 0..<scrollback.count where scrollback[index].mark.isPrompt {
            rows.append(base + index)
        }
        for row in 0..<self.rows where line(row).mark.isPrompt {
            rows.append(scrollback.totalPushed + row)
        }
        return rows
    }
}
