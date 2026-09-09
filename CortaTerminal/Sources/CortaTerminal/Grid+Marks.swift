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

    /// Every prompt row whose command finished with a non-zero status,
    /// oldest first, as absolute indices (U14).
    ///
    /// Separate from `promptRows` rather than a filter over it because the
    /// caller wants one or the other, never both, and the walk is the same
    /// cost either way.
    public var failedPromptRows: [Int] {
        promptRows(matching: { $0 == .promptFailed })
    }

    /// Every prompt row in the document, oldest first, as absolute indices.
    ///
    /// Walked rather than maintained as an index: a list would have to be
    /// fixed up by eviction, reflow, `resize` and the alternate-screen swap,
    /// and the walk costs one pass over lines that are already in memory —
    /// paid once per ⌘↑, not per frame.
    public var promptRows: [Int] { promptRows(matching: \.isPrompt) }

    private func promptRows(matching predicate: (LineMark) -> Bool) -> [Int] {
        var rows: [Int] = []
        let base = scrollback.totalPushed - scrollback.count
        for index in 0..<scrollback.count where predicate(scrollback[index].mark) {
            rows.append(base + index)
        }
        for row in 0..<self.rows where predicate(line(row).mark) {
            rows.append(scrollback.totalPushed + row)
        }
        return rows
    }

    /// Every row carrying an output-start mark (`OSC 133 ; C`), oldest
    /// first, as absolute indices (U14).
    public var outputStartRows: [Int] {
        promptRows(matching: { $0 == .outputStart })
    }

    /// U14 — the output of the completed command that most recently ended at
    /// or before `absoluteRow`, as an absolute row range.
    ///
    /// **Where the range starts.** From the command's `OSC 133 ; C` mark when
    /// the shell emitted one — that is exactly where the output begins, after
    /// the command line has been echoed. Only when there is no `C` mark does
    /// it fall back to one row past the prompt, which is right for a one-line
    /// prompt with the command typed on it and takes one row too much for a
    /// two-line prompt or a continued command. The fallback is for shells
    /// whose integration emits `A` and `D` but not `C`.
    ///
    /// - Parameter before: the absolute row to look back from. Passing the
    ///   top of a scrolled viewport is what makes "copy this command's
    ///   output" work on a command that is not the last one.
    ///
    /// `nil` when there is no completed command there: no marks at all (no
    /// shell integration), or only the prompt now waiting for input.
    public func commandOutputRows(before absoluteRow: Int = .max) -> Range<Int>? {
        let prompts = promptRows
        // The prompt that *ends* the command — the first one at or after the
        // command whose output is wanted.
        // No fallback to the newest prompt. A bound above every prompt means
        // there is no completed command at or before it, and answering with
        // the *last* command's output instead would copy something the user
        // is not looking at — the scrolled-viewport case this parameter
        // exists for is exactly where that would happen.
        guard let endIndex = prompts.lastIndex(where: { $0 <= absoluteRow }), endIndex > 0
        else { return nil }
        let end = prompts[endIndex]
        let promptRow = prompts[endIndex - 1]
        // The output mark belonging to *that* command: the last one after its
        // prompt and before the next.
        let outputStart = outputStartRows.last { $0 > promptRow && $0 < end }
        let start = outputStart ?? promptRow + 1
        return start < end ? start..<end : nil
    }

    /// The last completed command's output. Equivalent to
    /// `commandOutputRows(before:)` with no bound.
    public var lastCommandOutputRows: Range<Int>? { commandOutputRows() }
}
