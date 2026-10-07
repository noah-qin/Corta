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

/// IME composition (`DESIGN.md` §7.1). Routing is in
/// `TerminalView+Keyboard.swift`; committed text reaches the PTY only via
/// `insertText`; marked text never touches the grid or the PTY —
/// `MarkedTextOverlayView` draws it at the cursor.
extension TerminalView: NSTextInputClient {
    // MARK: - Marked text state

    /// The preedit state lives on the overlay: extensions have no storage.
    private var existingMarkedTextOverlay: MarkedTextOverlayView? {
        subviews.first(where: { $0 is MarkedTextOverlayView }) as? MarkedTextOverlayView
    }

    private var markedTextOverlay: MarkedTextOverlayView {
        if let existing = existingMarkedTextOverlay { return existing }
        let overlay = MarkedTextOverlayView()
        addSubview(overlay)
        return overlay
    }

    // MARK: - NSTextInputClient

    /// Committed text, the only IME output that reaches the child, via
    /// `onKeyBytes`. Plain typing commits through here too, not through
    /// `deliverBytes`, so the `keyDown` signpost is emitted here as well.
    func insertText(_ string: Any, replacementRange: NSRange) {
        clearMarkedText()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        if let event = NSApp.currentEvent { noteKeystrokeForMetrics(at: event.timestamp) }
        InputLatencySignposts.measure(.keyDown) { onKeyBytes?(Array(text.utf8)) }
    }

    /// Repositions and redraws the overlay; an empty string cancels.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString =
            switch string {
            case let a as NSAttributedString: a
            case let s as String: NSAttributedString(string: s)
            default: NSAttributedString()
            }
        guard attributed.length > 0 else {
            clearMarkedText()
            return
        }
        let overlay = markedTextOverlay
        // Re-read each time, so ⌘= / ⌘- mid-composition takes effect.
        if let font = preeditFontProvider?() { overlay.font = font }
        overlay.show(attributed, at: cursorRectProvider?() ?? .zero)
        inputCompositionRect = overlay.frame
        onInputContextChange?()
    }

    func unmarkText() {
        clearMarkedText()
    }

    /// Losing focus mid-composition discards the preedit — never commits
    /// half-composed input to the PTY.
    override func resignFirstResponder() -> Bool {
        clearMarkedText()
        let accepted = super.resignFirstResponder()
        onInputContextChange?()
        return accepted
    }

    private func clearMarkedText() {
        guard existingMarkedTextOverlay?.markedText != nil || inputCompositionRect != nil else { return }
        existingMarkedTextOverlay?.hide()
        inputCompositionRect = nil
        onInputContextChange?()
    }

    func hasMarkedText() -> Bool {
        existingMarkedTextOverlay?.markedText != nil
    }

    func markedRange() -> NSRange {
        guard let length = existingMarkedTextOverlay?.markedText?.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: length)
    }

    /// No backing store is exposed to input methods.
    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, .font, .foregroundColor]
    }

    /// The cursor cell in screen coordinates, computed on demand so it
    /// follows window moves.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let cell = cursorRectProvider?(), let window else { return .zero }
        return window.convertToScreen(convert(cell, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// Commands an IME resolved instead of inserting text; forwarded so
    /// Return, Delete, Escape and arrows behave the same with any IME.
    /// Signposted like `insertText`.
    override func doCommand(by selector: Selector) {
        // The key itself, when the IME answered a terminal key with a command:
        // the direct translation keeps DECCKM, LNM, modifiers and the kitty
        // flags, which the selector alone has lost. Terminal keys outside a
        // composition never get here (`routesEventThroughIME`).
        if let event = NSApp.currentEvent, event.type == .keyDown,
            event.window == nil || event.window === window, Self.isTerminalKey(event)
        {
            deliverBytes(for: event)
            return
        }
        let bytes: [UInt8]?
        switch selector {
        case #selector(insertNewline(_:)):
            bytes = isNewLineMode?() == true ? [0x0D, 0x0A] : [0x0D]
        case #selector(deleteBackward(_:)): bytes = [0x7F]
        case #selector(cancelOperation(_:)): bytes = [0x1B]
        case #selector(moveUp(_:)): bytes = Array("\u{1B}[A".utf8)
        case #selector(moveDown(_:)): bytes = Array("\u{1B}[B".utf8)
        case #selector(moveRight(_:)): bytes = Array("\u{1B}[C".utf8)
        case #selector(moveLeft(_:)): bytes = Array("\u{1B}[D".utf8)
        // A candidate window can resolve Tab and Shift-Tab as commands. Only
        // Shift reaches here (⌘/⌃ bypass the IME), matching the unmodified
        // Shift-Tab case in `TerminalView+Keyboard.swift`.
        case #selector(insertTab(_:)): bytes = [0x09]
        case #selector(insertBacktab(_:)): bytes = Array("\u{1B}[Z".utf8)
        default: bytes = nil
        }
        guard let bytes else { return }
        if let event = NSApp.currentEvent { noteKeystrokeForMetrics(at: event.timestamp) }
        InputLatencySignposts.measure(.keyDown) { onKeyBytes?(bytes) }
    }
}

/// Draws the preedit over the cursor cells, above the Metal layer, with no
/// backdrop (as Terminal.app). Never takes events.
final class MarkedTextOverlayView: NSView {
    /// The preedit with the IME's attributes; nil while hidden.
    private(set) var markedText: NSAttributedString?

    /// Re-pointed at the current size on each `show`
    /// (`TerminalView.preeditFontProvider`).
    var font = NSFont.monospacedSystemFont(
        ofSize: ViewController.defaultFontSize, weight: .medium)

    /// The renderer's text colour, read live so it follows theme and
    /// appearance.
    private var textColor: NSColor {
        let color = TerminalColorPalette.defaultForeground
        return NSColor(
            srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
            alpha: CGFloat(color.w))
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Without its own layer it can't composite over the hosting view's
        // Metal layer.
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        isHidden = true
    }

    /// Shows the preedit at `cell` (current size, from the provider), at
    /// least a cell wide and clamped to the pane: AppKit doesn't clip
    /// subviews, so it would paint over a split's divider.
    func show(_ attributed: NSAttributedString, at cell: CGRect) {
        let display = displayString(for: attributed)
        markedText = display
        let textSize = display.size()
        let available = superview.map { max(0, $0.bounds.maxX - cell.minX) }
            ?? .greatestFiniteMagnitude
        frame = CGRect(
            x: cell.minX, y: cell.minY,
            width: min(max(ceil(textSize.width), cell.width), max(cell.width, available)),
            height: max(cell.height, ceil(textSize.height)))
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        markedText = nil
        isHidden = true
    }

    /// Fills in font and colour only where the IME set none.
    private func displayString(for attributed: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributed)
        // Collect first: no mutation mid-enumeration.
        var additions: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var defaults: [NSAttributedString.Key: Any] = [:]
            if attributes[.font] == nil { defaults[.font] = font }
            if attributes[.foregroundColor] == nil { defaults[.foregroundColor] = textColor }
            if !defaults.isEmpty { additions.append((range, defaults)) }
        }
        for (range, defaults) in additions {
            text.addAttributes(defaults, range: range)
        }
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let markedText else { return }
        // Centred in the cell; AppKit draws the underline.
        let y = max(0, (bounds.height - markedText.size().height) / 2)
        markedText.draw(at: NSPoint(x: 0, y: y))
    }
}
