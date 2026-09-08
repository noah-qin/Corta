import AppKit

/// VoiceOver, Switch Control, Voice Control and every other assistive
/// technology, for a view that draws its text with Metal.
///
/// **The problem this closes.** A `CAMetalLayer` is pixels. AppKit derives an
/// accessibility tree from views and their text, and a view that renders its
/// own glyphs into a drawable has none to derive — so the entire terminal was
/// one unlabelled rectangle, and the app's most important content was the only
/// content no screen reader could reach. Nothing about that is visible in a
/// render test: the pixels were right the whole time.
///
/// **The shape of the fix.** A terminal *is* a text area — a fixed grid of
/// characters with an insertion point and a selection — so it implements the
/// text-area protocol rather than inventing a role. The text, the cursor and
/// the selection come from `accessibilitySnapshotProvider`, installed by the
/// pane: this view knows nothing about `Grid`, the same way it knows nothing
/// about the session for keys or the renderer for metrics (`ViewController`
/// owns every closure hook here).
///
/// The snapshot is rebuilt at most once per burst of questions, because
/// AppKit asks a dozen of them per VoiceOver step and each would otherwise
/// take the terminal's lock and walk the grid.
extension TerminalView {
    // MARK: - Element identity

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { L10n.text("a11y.terminal.label") }

    /// The grid's size — the fact that explains why a program's output is
    /// wrapped where it is, and the one thing a person who cannot see the
    /// window has no other way to learn.
    override func accessibilityHelp() -> String? {
        guard let snapshot = accessibilitySnapshot() else { return nil }
        return L10n.format(
            "a11y.terminal.help", snapshot.rows, snapshot.columns,
            snapshot.cursorRow + 1, snapshot.cursorColumn + 1)
    }

    // MARK: - Text

    override func accessibilityValue() -> Any? { accessibilitySnapshot()?.text }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilitySnapshot()?.text.utf16.count ?? 0
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let snapshot = accessibilitySnapshot() else { return nil }
        let full = snapshot.text as NSString
        guard let clamped = Self.clamp(range, to: full.length) else { return nil }
        return full.substring(with: clamped)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        // The exposed value *is* the viewport, so all of it is visible.
        NSRange(location: 0, length: accessibilitySnapshot()?.text.utf16.count ?? 0)
    }

    // MARK: - Cursor and selection

    override func accessibilitySelectedTextRange() -> NSRange {
        accessibilitySnapshot()?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = accessibilitySnapshot(), snapshot.selectedRange.length > 0
        else { return nil }
        return (snapshot.text as NSString).substring(with: snapshot.selectedRange)
    }

    /// The *visible* line the cursor is on. `cursorRow` is a document row,
    /// and the two differ by the scroll offset — scrolled into the history,
    /// the cursor's line number was being reported as if the live screen were
    /// still on top of the viewport (U01).
    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let snapshot = accessibilitySnapshot() else { return 0 }
        return min(max(0, snapshot.cursorRow + snapshot.scrollOffset), max(0, snapshot.rows - 1))
    }

    // MARK: - Lines

    override func accessibilityLine(for index: Int) -> Int {
        guard let snapshot = accessibilitySnapshot() else { return 0 }
        // The last row whose start is at or before the offset. Rows are few
        // (tens) and the answer is asked for per VoiceOver step, so a scan
        // beats maintaining a second index.
        var line = 0
        for (row, start) in snapshot.lineStarts.enumerated() where start <= index { line = row }
        return line
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let snapshot = accessibilitySnapshot(),
            line >= 0, line < snapshot.lineStarts.count
        else { return NSRange(location: 0, length: 0) }
        let start = snapshot.lineStarts[line]
        let end =
            line + 1 < snapshot.lineStarts.count
            // Minus the newline: the range is the line, not the separator.
            ? max(start, snapshot.lineStarts[line + 1] - 1)
            : snapshot.text.utf16.count
        return NSRange(location: start, length: end - start)
    }

    /// The character under a point, which the protocol gives in **screen**
    /// coordinates.
    ///
    /// Two conversions were wrong here (U01). `convert(_:from: nil)` converts
    /// from *window* coordinates, not screen, so every answer was off by the
    /// window's origin — the further from the bottom-left of the display the
    /// window sat, the further Voice Control's click landed from the cell the
    /// user named. And the offset was `line.location + cell.column`, which
    /// treats a UTF-16 offset and a grid column as the same number; they are
    /// the same number only for ASCII.
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let snapshot = accessibilitySnapshot(), let cellAtPoint else {
            return NSRange(location: 0, length: 0)
        }
        // Screen -> window -> view. Without a window there is no screen
        // space to come from, so the point cannot be resolved at all.
        guard let window else { return NSRange(location: 0, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        // `cellAtPoint` answers in viewport rows (it is shared with mouse
        // reporting, which names on-screen cells); the snapshot indexes by
        // document row, so the scroll offset comes back off here.
        let cell = cellAtPoint(local)
        guard cell.row >= 0, cell.row < snapshot.lineStarts.count else {
            return NSRange(location: 0, length: 0)
        }
        let documentRow = cell.row - snapshot.scrollOffset
        return NSRange(
            location: snapshot.offset(documentRow: documentRow, column: cell.column), length: 0)
    }

    /// Where a character range is on screen, so VoiceOver's cursor outline
    /// lands on the text it is reading rather than around the whole pane.
    ///
    /// The columns come from the snapshot's boundary table, not from
    /// `offset - lineStart` (U01): on a row of CJK that subtraction is half
    /// the true column, and the outline lands on the wrong half of the line.
    /// The range's last *character* is what bounds the rectangle, so a
    /// zero-length range still outlines one cell.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let cellFrame = accessibilityCellFrameProvider,
            let snapshot = accessibilitySnapshot()
        else { return .zero }
        let start = snapshot.cell(forOffset: range.location)
        let end = snapshot.cell(forOffset: range.location + max(0, range.length - 1))
        let first = cellFrame(start.row, start.column)
        let last = cellFrame(end.row, end.column)
        let rect = first.union(last)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: - Snapshot caching

    /// Rebuilds at most once per `snapshotLifetime`. AppKit asks its dozen
    /// questions back to back, so one copy answers a whole VoiceOver step
    /// consistently; the cache is dropped by `noteAccessibilityValueChanged`
    /// the moment the grid moves on.
    private func accessibilitySnapshot() -> TerminalAccessibilitySnapshot? {
        if let cached = cachedAccessibilitySnapshot,
            CACurrentMediaTime() - cachedAccessibilitySnapshotTime < Self.snapshotLifetime
        {
            return cached
        }
        guard let snapshot = accessibilitySnapshotProvider?() else { return nil }
        cachedAccessibilitySnapshot = snapshot
        cachedAccessibilitySnapshotTime = CACurrentMediaTime()
        return snapshot
    }

    static let snapshotLifetime: CFTimeInterval = 0.2

    /// Called by the pane when the grid changed. Drops the cache and tells
    /// AppKit, so a screen reader following a build log hears the new lines
    /// instead of the ones from when it last asked.
    ///
    /// Rate-limited and gated on VoiceOver actually running: posting per frame
    /// would put string building on the render path, which is the one place
    /// the project's performance rules forbid it (`PERFORMANCE.md` §2).
    func noteAccessibilityValueChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastAccessibilityPost >= Self.accessibilityPostInterval else { return }
        lastAccessibilityPost = now
        cachedAccessibilitySnapshot = nil
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// The selection changed by a local action (a drag, Select All), which is
    /// a separate notification from the value changing.
    func noteAccessibilitySelectionChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        cachedAccessibilitySnapshot = nil
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    static let accessibilityPostInterval: CFTimeInterval = 0.4

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location >= 0, range.location <= length else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }
}
