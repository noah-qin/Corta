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
import CoreText
import CortaTerminal

/// Native overlays are drawn separately from terminal cells, beside the caret.
/// The command-status rules themselves are drawn by `TerminalRenderer`, with
/// the text they belong to (#238); this view keeps only their tooltips.
final class ShellOverlayView: NSView {
    struct Status: Equatable {
        var rect: CGRect
        var description: String
    }
    var statuses: [Status] = []
    var completion: DirectoryCompletion?
    var historySuggestion: HistorySuggestion?
    private var suppressedHistoryRevision: Int?
    /// Preedit and shell hints share the caret. Keep shell refreshes
    /// from recreating a hint underneath the input method's native overlay.
    var isInputComposing = false {
        didSet { if isInputComposing { hideCompletion() } }
    }
    fileprivate struct CompletionPresentation: Equatable {
        // periphery:ignore - read by the synthesised ==
        var state: DirectoryCompletion?
        // periphery:ignore - read by the synthesised ==
        var history: HistorySuggestion?
        // periphery:ignore - read by the synthesised ==
        var anchor: CGRect
        // periphery:ignore - read by the synthesised ==
        var bounds: CGRect
        // periphery:ignore - read by the synthesised ==
        var font: NSFont
        // periphery:ignore - read by the synthesised ==
        var baseline: CGFloat
        // periphery:ignore - read by the synthesised ==
        var composing: Bool
        /// A theme, appearance or contrast change must redraw a hint
        /// already showing.
        var colors: CanvasTextColors
    }
    private var lastCompletionPresentation: CompletionPresentation?
    private var preview: ShellGhostView?
    private var candidateRow: DirectoryCandidateRowView?
    /// Native hint frames, used to keep other overlays clear.
    var occupiedRects: [CGRect] { subviews.filter { !$0.isHidden }.map(\.frame) }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateStatuses(_ rows: [Status]) {
        guard statuses != rows else { return }
        statuses = rows
        removeAllToolTips()
        for row in rows { addToolTip(row.rect.insetBy(dx: -3, dy: 0), owner: self, userData: nil) }
    }

    @objc func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        statuses.first { $0.rect.insetBy(dx: -3, dy: 0).contains(point) }?.description ?? ""
    }

    /// - Parameter colors: the frame's canvas colours, read once for every
    ///   overlay that frame draws.
    func showCompletion(_ state: DirectoryCompletion?, history: HistorySuggestion? = nil, anchor: CGRect,
        font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular), baseline: CGFloat = 12,
        colors: CanvasTextColors = .current) {
        let presentation = CompletionPresentation(
            state: state, history: history, anchor: anchor, bounds: bounds,
            font: font, baseline: baseline, composing: isInputComposing,
            colors: colors)
        guard lastCompletionPresentation != presentation else { return }
        if isInputComposing, let history { suppressedHistoryRevision = history.revision }
        // ZLE reports before repainting BUFFER. A later echo may move the
        // anchor for this same revision; only input or an empty shell report
        // dismisses it, otherwise split PTY reads would lose valid hints.
        lastCompletionPresentation = presentation
        guard !isInputComposing,
            history == nil || history?.revision != suppressedHistoryRevision,
            let suffix = history?.suffix ?? state?.previewSuffix, !suffix.isEmpty else {
            completion = nil
            historySuggestion = nil
            preview?.removeFromSuperview()
            preview = nil
            candidateRow?.removeFromSuperview()
            candidateRow = nil
            return
        }
        completion = state
        historySuggestion = history
        let colors = HintColors(presentation)
        if history != nil || state?.typedPrefix.isEmpty == false {
            let ghost = preview ?? ShellGhostView()
            ghost.text = suffix
            ghost.history = history != nil
            ghost.font = font
            ghost.color = colors.muted
            ghost.baseline = baseline
            ghost.frame = CGRect(x: anchor.minX, y: anchor.minY,
                width: max(0, bounds.width - TerminalLayout.insets.right - anchor.minX), height: anchor.height)
            ghost.toolTip = L10n.text(history != nil ? "completion.historyHint" : "completion.hint")
            if preview == nil { addSubview(ghost)
                preview = ghost }
            ghost.needsDisplay = true
        } else {
            preview?.removeFromSuperview()
            preview = nil
        }
        // Once the prefix resolves to one folder, the inline suffix is enough.
        guard history == nil, let state, state.typedPrefix.isEmpty || state.candidates.count > 1 else {
            candidateRow?.removeFromSuperview()
            candidateRow = nil
            return
        }
        let row = candidateRow ?? DirectoryCandidateRowView()
        let padding: CGFloat = 8
        let margin = TerminalLayout.insets.left
        let availableWidth = max(0, bounds.width - margin - TerminalLayout.insets.right)
        row.frame.size = CGSize(width: availableWidth, height: anchor.height + 10)
        row.baseline = baseline + 5
        row.update(state: state, font: font, colors: colors)
        let width = min(availableWidth, row.fittingWidth)
        let prefixWidth = (state.typedPrefix as NSString).size(withAttributes: [.font: font]).width
        let x = min(max(margin, anchor.minX - prefixWidth - padding),
            max(margin, bounds.width - TerminalLayout.insets.right - width))
        let below = anchor.maxY + 4
        let height = row.frame.height
        let fitsBelow = below + height <= bounds.height - TerminalLayout.insets.bottom
        row.frame = CGRect(x: x,
            y: fitsBelow ? below : max(0, anchor.minY - height - 4),
            width: width, height: height)
        row.toolTip = L10n.text("completion.hint")
        if candidateRow == nil { addSubview(row)
            candidateRow = row }
        row.needsDisplay = true
    }

    func hideCompletion() {
        if let historySuggestion { suppressedHistoryRevision = historySuggestion.revision }
        showCompletion(nil, anchor: .zero)
    }

    /// History hints take only acceptance and dismissal, with native Tab
    /// and all history-navigation keys left to the shell.
    static func historyKeySequence(for event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else { return nil }
        switch event.keyCode {
        case 124, 119: return "\u{1b}[95~" // Right, End
        case 53: return "\u{1b}[94~" // Escape
        default: return nil
        }
    }

    /// The canvas text colour, faded for the hint (`CanvasTextColors`).
    fileprivate struct HintColors {
        var muted: CGColor
        var selected: CGColor
        var backdrop: CGColor
        var border: CGColor
        var candidate: CGColor

        init(_ presentation: CompletionPresentation) {
            muted = presentation.colors.text(alpha: 0.35, contrastAlpha: 0.7)
            selected = presentation.colors.text(alpha: 0.85, contrastAlpha: 1)
            backdrop = presentation.colors.backdrop
            border = presentation.colors.text(alpha: 0.2, contrastAlpha: 0.6)
            candidate = presentation.colors.text(alpha: 0.65, contrastAlpha: 1)
        }
    }
}

/// CoreText uses the renderer's font and baseline, so the suggestion reads as
/// part of the command line. It remains outside the grid and copied text.
private final class ShellGhostView: NSView {
    var text = ""
    var history = false
    var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var baseline: CGFloat = 12
    var color = CGColor(gray: 0.5, alpha: 0.35)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityIdentifier() -> String { history ? "history-suggestion-preview" : "directory-completion-preview" }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: color]))
        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// A compact panel beside the input; its border distinguishes it from history.
private final class DirectoryCandidateRowView: NSView {
    private var content = NSAttributedString(string: "")
    private var token = NSAttributedString(string: "…")
    private var visibleText = ""
    var baseline: CGFloat = 12
    private var backdrop = CGColor(gray: 1, alpha: 1)
    private var border = CGColor(gray: 0, alpha: 0.2)
    var fittingWidth: CGFloat { ceil(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(content), nil, nil, nil)) + 16 }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { visibleText }
    override func accessibilityValue() -> Any? { visibleText }
    override func accessibilityIdentifier() -> String { "directory-completion-candidates" }

    fileprivate func update(state: DirectoryCompletion, font: NSFont, colors: ShellOverlayView.HintColors) {
        let gap = "  "
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        backdrop = colors.backdrop
        border = colors.border
        let available = max(0, bounds.width - 16 - width("…    …"))
        var start = state.selectedIndex
        var end = start + 1
        var used = width(state.candidates[start])
        // Keep the selection visible as arrows move through more candidates.
        while start > 0 && end - start < 5 {
            let extra = width(gap + state.candidates[start - 1])
            guard used + extra <= available else { break }
            used += extra
            start -= 1
        }
        while end < state.candidates.count && end - start < 5 {
            let extra = width(gap + state.candidates[end])
            guard used + extra <= available else { break }
            used += extra
            end += 1
        }
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.candidate]
        let result = NSMutableAttributedString(string: start > 0 ? "…  " : "", attributes: muted)
        for index in start..<end {
            if index > start { result.append(NSAttributedString(string: gap, attributes: muted)) }
            var attributes = muted
            if index == state.selectedIndex {
                attributes[.foregroundColor] = colors.selected
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: state.candidates[index], attributes: attributes))
        }
        if end < state.candidates.count { result.append(NSAttributedString(string: "  …", attributes: muted)) }
        content = result
        // Truncation is not part of the selection, even beside it.
        token = NSAttributedString(string: "…", attributes: muted)
        visibleText = result.string
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let panel = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(panel)
        context.setFillColor(backdrop)
        context.setStrokeColor(border)
        context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        let full = CTLineCreateWithAttributedString(content)
        let ellipsis = CTLineCreateWithAttributedString(token)
        let line = CTLineCreateTruncatedLine(full, Double(max(0, bounds.width - 16)), .end, ellipsis) ?? full
        context.saveGState()
        context.clip(to: bounds.insetBy(dx: 8, dy: 0))
        context.translateBy(x: 8, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
