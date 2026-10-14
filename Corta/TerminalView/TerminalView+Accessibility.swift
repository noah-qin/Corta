// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import OSLog

/// Assistive technology support for a view that draws its text with Metal,
/// which gives AppKit nothing to derive an accessibility tree from.
///
/// The view implements the text-area protocol: a fixed grid of characters
/// with an insertion point and a selection. Text, cursor and selection come
/// from `accessibilitySnapshotProvider`, installed by the pane, so this
/// view knows nothing about `Grid`. The snapshot is rebuilt at most once per
/// burst, since AppKit asks a dozen questions per VoiceOver step.
extension TerminalView {
    /// What an assistive client asked and was told, at notice level so it is
    /// there afterwards (`log show --predicate 'subsystem ==
    /// "dev.noahqin.Corta" and category == "accessibility"'`). VoiceOver
    /// can't run in a test and never says which attribute it read; this does.
    private static let trace = Logger(subsystem: "dev.noahqin.Corta", category: "accessibility")

    // MARK: - Element identity

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { L10n.text("a11y.terminal.label") }

    /// The grid size, which explains where output wraps.
    override func accessibilityHelp() -> String? {
        guard let snapshot = accessibilitySnapshot() else { return nil }
        return L10n.format(
            "a11y.terminal.help", snapshot.rows, snapshot.columns,
            snapshot.cursorRow + 1, snapshot.cursorColumn + 1)
    }

    // MARK: - Text

    override func accessibilityValue() -> Any? {
        Self.trace.notice("value")
        return accessibilitySnapshot()?.text
    }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilitySnapshot()?.text.utf16.count ?? 0
    }

    override func accessibilityString(for range: NSRange) -> String? {
        Self.trace.notice("string(for:) \(range.location, privacy: .public)+\(range.length, privacy: .public)")
        guard let snapshot = accessibilitySnapshot() else { return nil }
        let full = snapshot.text as NSString
        guard let clamped = Self.clamp(range, to: full.length) else { return nil }
        return full.substring(with: clamped)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        // The value is the viewport, so all of it is visible.
        NSRange(location: 0, length: accessibilitySnapshot()?.text.utf16.count ?? 0)
    }

    /// `AXAttributedStringForRange`, which VoiceOver asks when speaking a
    /// range; without it, it said "No selection." over a real selection.
    /// Plain text: colour and bold aren't semantics.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        Self.trace.notice("attributedString(for:) \(range.location, privacy: .public)+\(range.length, privacy: .public)")
        guard let text = accessibilityString(for: range) else { return nil }
        return NSAttributedString(string: text)
    }

    /// `AXRangeForIndex`: the whole grapheme, never half an emoji or
    /// combining sequence.
    override func accessibilityRange(for index: Int) -> NSRange {
        guard let snapshot = accessibilitySnapshot() else { return NSRange(location: 0, length: 0) }
        let full = snapshot.text as NSString
        guard index >= 0, index < full.length else {
            return NSRange(location: full.length, length: 0)
        }
        return full.rangeOfComposedCharacterSequence(at: index)
    }

    /// `AXStyleRangeForIndex`: the text has no attributes, so a line.
    override func accessibilityStyleRange(for index: Int) -> NSRange {
        accessibilityRange(forLine: accessibilityLine(for: index))
    }

    // MARK: - Cursor and selection

    override func accessibilitySelectedTextRange() -> NSRange {
        let range = accessibilitySnapshot()?.selectedRange ?? NSRange(location: 0, length: 0)
        Self.trace.notice("selectedTextRange -> \(range.location, privacy: .public)+\(range.length, privacy: .public)")
        return range
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = accessibilitySnapshot(), snapshot.selectedRange.length > 0
        else {
            Self.trace.notice("selectedText -> nil")
            return nil
        }
        let text = (snapshot.text as NSString).substring(with: snapshot.selectedRange)
        Self.trace.notice("selectedText -> \(text.utf16.count, privacy: .public) units")
        return text
    }

    /// `AXSelectedTextRanges`: the one selection, or empty — not a
    /// zero-length range, which would mean one empty selection.
    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard let snapshot = accessibilitySnapshot(), snapshot.selectedRange.length > 0
        else {
            Self.trace.notice("selectedTextRanges -> []")
            return []
        }
        Self.trace.notice("selectedTextRanges -> [\(snapshot.selectedRange.location, privacy: .public)+\(snapshot.selectedRange.length, privacy: .public)]")
        return [NSValue(range: snapshot.selectedRange)]
    }

    /// The visible line: `cursorRow` is a document row, off by the scroll
    /// offset.
    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let snapshot = accessibilitySnapshot() else { return 0 }
        return min(max(0, snapshot.cursorRow + snapshot.scrollOffset), max(0, snapshot.rows - 1))
    }

    // MARK: - Lines

    override func accessibilityLine(for index: Int) -> Int {
        guard let snapshot = accessibilitySnapshot() else { return 0 }
        // Rows are few; a scan beats a second index.
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
            // Minus the newline.
            ? max(start, snapshot.lineStarts[line + 1] - 1)
            : snapshot.text.utf16.count
        return NSRange(location: start, length: end - start)
    }

    /// The character under a point, given in screen coordinates. Converted
    /// screen → window → view (`convert(_:from: nil)` alone is window
    /// coordinates), and mapped column to UTF-16 offset through the snapshot,
    /// since they match only for ASCII.
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let snapshot = accessibilitySnapshot(), let cellAtPoint else {
            return NSRange(location: 0, length: 0)
        }
        guard let window else { return NSRange(location: 0, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        // `cellAtPoint` answers in viewport rows; the snapshot wants document
        // rows.
        let cell = cellAtPoint(local)
        guard cell.row >= 0, cell.row < snapshot.lineStarts.count else {
            return NSRange(location: 0, length: 0)
        }
        let documentRow = cell.row - snapshot.scrollOffset
        return NSRange(
            location: snapshot.offset(documentRow: documentRow, column: cell.column), length: 0)
    }

    /// A range's screen rect, for VoiceOver's outline. Columns come from the
    /// snapshot's boundary table (subtraction halves CJK); a zero-length range
    /// still outlines one cell.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let cellFrame = accessibilityCellFrameProvider,
            let snapshot = accessibilitySnapshot()
        else { return .zero }
        let start = snapshot.cell(forOffset: range.location)
        // The last character's last column, or a wide character is half
        // outlined.
        let end = snapshot.cellSpan(forOffset: range.location + max(0, range.length - 1))
        let first = cellFrame(start.row, start.column)
        let last = cellFrame(end.row, end.column + end.columns - 1)
        let rect = first.union(last)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: - Snapshot caching

    /// Rebuilds at most once per `snapshotLifetime`, so a VoiceOver step is
    /// answered consistently; `noteAccessibilityValueChanged` drops it.
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

    /// The grid changed: drop the cache and notify, so VoiceOver hears new
    /// output. Rate-limited and only while VoiceOver runs, keeping string
    /// building off the render path (`PERFORMANCE.md` §2).
    func noteAccessibilityValueChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        // Whatever happens to the notification, the old snapshot is stale.
        cachedAccessibilitySnapshot = nil
        let now = CACurrentMediaTime()
        let elapsed = now - lastAccessibilityPost
        guard elapsed >= Self.accessibilityPostInterval else {
            // Trail rather than drop, or a burst's final state is never announced.
            guard pendingAccessibilityPost == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingAccessibilityPost = nil
                self.lastAccessibilityPost = CACurrentMediaTime()
                self.cachedAccessibilitySnapshot = nil
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
            pendingAccessibilityPost = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.accessibilityPostInterval - elapsed), execute: item)
            return
        }
        lastAccessibilityPost = now
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// A local selection change: its own notification, separate from value.
    func noteAccessibilitySelectionChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        cachedAccessibilitySnapshot = nil
        Self.trace.notice("post selectedTextChanged")
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    static let accessibilityPostInterval: CFTimeInterval = 0.4

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location >= 0, range.location <= length else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }
}
