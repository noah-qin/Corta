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

    /// U14 — the output of the last command that has a prompt after it, as
    /// the absolute row range `prompt + 1 ..< nextPrompt`.
    ///
    /// **What this can and cannot know.** `OSC 133 ; A` marks where a prompt
    /// begins; Corta does not implement `OSC 133 ; C`, which is what would
    /// mark where the *command line* ends and the output begins. So the range
    /// starts one row after the prompt, which is right for the ordinary case
    /// — a one-line prompt with the command typed on it — and wrong for a
    /// two-line prompt or a command continued across lines, where the first
    /// row of the "output" is really the rest of what was typed. That is a
    /// visible, explainable inaccuracy rather than a silent one, and closing
    /// it means implementing `C` marks, not guessing here.
    ///
    /// `nil` when there is no completed command to take the output of: no
    /// marks at all (no shell integration), or only the prompt now waiting
    /// for input.
    public var lastCommandOutputRows: Range<Int>? {
        let prompts = promptRows
        guard prompts.count >= 2 else { return nil }
        let start = prompts[prompts.count - 2] + 1
        let end = prompts[prompts.count - 1]
        return start < end ? start..<end : nil
    }
}
