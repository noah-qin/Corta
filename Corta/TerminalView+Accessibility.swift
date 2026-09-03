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

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilitySnapshot()?.cursorRow ?? 0
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

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let snapshot = accessibilitySnapshot(), let cellAtPoint else {
            return NSRange(location: 0, length: 0)
        }
        let local = convert(point, from: nil)
        let cell = cellAtPoint(local)
        guard cell.row >= 0, cell.row < snapshot.lineStarts.count else {
            return NSRange(location: 0, length: 0)
        }
        let line = accessibilityRange(forLine: cell.row)
        let offset = min(line.location + cell.column, line.location + line.length)
        return NSRange(location: offset, length: 0)
    }

    /// Where a character range is on screen, so VoiceOver's cursor outline
    /// lands on the text it is reading rather than around the whole pane.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let cellFrame = accessibilityCellFrameProvider else { return .zero }
        let line = accessibilityLine(for: range.location)
        let lineRange = accessibilityRange(forLine: line)
        let startColumn = max(0, range.location - lineRange.location)
        let endColumn = max(startColumn + 1, startColumn + range.length)
        let first = cellFrame(line, startColumn)
        let last = cellFrame(line, endColumn - 1)
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
