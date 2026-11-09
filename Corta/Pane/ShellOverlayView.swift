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
    /// Liquid Glass behind the candidates, a sibling below the row so the
    /// row stays the element tests and VoiceOver find.
    private var candidateGlass: NSGlassEffectView?
    /// Native hint frames, used to keep other overlays clear; the glass
    /// shares the candidates' frame.
    var occupiedRects: [CGRect] {
        subviews.filter { !$0.isHidden && $0 !== candidateGlass }.map(\.frame)
    }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateStatuses(_ rows: [Status]) {
        guard statuses != rows else { return }
        statuses = rows
        removeAllToolTips()
        for row in rows { addToolTip(row.rect.insetBy(dx: -3, dy: 0), owner: self, userData: nil) }
    }

    @objc func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        statuses.first { $0.rect.insetBy(dx: -3, dy: 0).contains(point) }?.description ?? ""
    }

    /// - Parameter colors: the frame's canvas colours, read once for every
    ///   overlay that frame draws.
    /// - Parameter state: the shell's authenticated directory candidates.
    /// - Parameter history: the shell's authenticated history suffix, if any.
    /// - Parameter anchor: the input caret's rectangle in this view.
    /// - Parameter font: the terminal font used to measure and draw hints.
    /// - Parameter baseline: the text baseline offset within the anchor row.
    func showCompletion(
        _ state: DirectoryCompletion?, history: HistorySuggestion? = nil, anchor: CGRect,
        font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular), baseline: CGFloat = 12,
        colors: CanvasTextColors = .current
    ) {
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
            removeCandidates()
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
            removeCandidates()
            return
        }
        showCandidates(state, anchor: anchor, font: font, baseline: baseline, colors: colors)
    }

    /// The candidate folders on a glass row under the caret, or above it
    /// where the pane has no room below; left-aligned with the typed prefix.
    private func showCandidates(
        _ state: DirectoryCompletion, anchor: CGRect, font: NSFont, baseline: CGFloat, colors: HintColors
    ) {
        let row = candidateRow ?? DirectoryCandidateRowView()
        let padding = DirectoryCandidateRowView.textInset(for: font)
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
        let glass = candidateGlass ?? NSGlassEffectView()
        glass.frame = row.frame
        glass.cornerRadius = row.frame.height / 2
        if candidateGlass == nil { addSubview(glass)
            candidateGlass = glass }
        if candidateRow == nil { addSubview(row, positioned: .above, relativeTo: glass)
            candidateRow = row }
        row.needsDisplay = true
    }

    private func removeCandidates() {
        candidateRow?.removeFromSuperview()
        candidateRow = nil
        candidateGlass?.removeFromSuperview()
        candidateGlass = nil
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
    override func accessibilityIdentifier() -> String {
        history ? "history-suggestion-preview" : "directory-completion-preview"
    }

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

/// A compact capsule beside the input, over glass: a folder mark, then the
/// candidate folders, the chosen one held in a soft chip of its own. Its
/// hairline distinguishes it from a history suggestion.
private final class DirectoryCandidateRowView: NSView {
    private var content = NSAttributedString(string: "")
    private var token = NSAttributedString(string: "…")
    private var visibleText = ""
    /// Where the chosen folder is in `content`, for its chip.
    private var selectedRange = NSRange(location: NSNotFound, length: 0)
    private var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var baseline: CGFloat = 12
    private var backdrop = CGColor(gray: 1, alpha: 1)
    private var border = CGColor(gray: 0, alpha: 0.2)
    private var chip = CGColor(gray: 0, alpha: 0.08)
    private var mark = CGColor(gray: 0, alpha: 0.5)
    /// The folder mark's inset from the capsule's leading end, past its curve.
    static let inset: CGFloat = 10
    /// Room the chip takes either side of the chosen name.
    static let chipPadding: CGFloat = 6
    static func markSize(for font: NSFont) -> CGFloat { (font.pointSize * 0.9).rounded() }
    /// Where the names start: past the folder mark and a gap.
    static func textInset(for font: NSFont) -> CGFloat { inset + markSize(for: font) + 8 }
    var fittingWidth: CGFloat { ceil(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(content), nil, nil, nil)) + Self.textInset(for: font) + 12 }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { visibleText }
    override func accessibilityValue() -> Any? { visibleText }
    override func accessibilityIdentifier() -> String { "directory-completion-candidates" }

    fileprivate func update(state: DirectoryCompletion, font: NSFont, colors: ShellOverlayView.HintColors) {
        self.font = font
        let gap = "   "
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        backdrop = colors.backdrop
        border = colors.border
        chip = colors.selected.copy(alpha: 0.1) ?? colors.border
        mark = colors.candidate
        // Room for both ends cut: "…" and a gap before, a gap and "+N" after.
        let available = max(0, bounds.width - Self.textInset(for: font) - 12 - width("…" + gap + gap + "+999"))
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
        let faint: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.muted]
        let result = NSMutableAttributedString(string: start > 0 ? "…" + gap : "", attributes: faint)
        selectedRange = NSRange(location: NSNotFound, length: 0)
        for index in start..<end {
            if index > start { result.append(NSAttributedString(string: gap, attributes: muted)) }
            var attributes = muted
            if index == state.selectedIndex { attributes[.foregroundColor] = colors.selected }
            // The trailing slash says "folder" once the mark has; it fades.
            var name = state.candidates[index]
            let slash = name.hasSuffix("/")
            if slash { name.removeLast() }
            let location = result.length
            result.append(NSAttributedString(string: name, attributes: attributes))
            if slash { result.append(NSAttributedString(string: "/", attributes: faint)) }
            if index == state.selectedIndex {
                selectedRange = NSRange(location: location, length: result.length - location)
            }
        }
        // How many more there are, rather than a bare ellipsis.
        let more = state.candidates.count - end
        if more > 0 { result.append(NSAttributedString(string: gap + "+\(more)", attributes: faint)) }
        content = result
        // Truncation is not part of the selection, even beside it.
        token = NSAttributedString(string: "…", attributes: muted)
        visibleText = result.string
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = bounds.height / 2
        let panel = CGPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
            cornerWidth: radius - 0.25, cornerHeight: radius - 0.25, transform: nil)
        context.addPath(panel)
        // The canvas colour, thinned so the glass beneath shows through
        // while the theme's text keeps its contrast; a hairline, not a
        // frame, so the capsule reads as one surface.
        context.setFillColor(backdrop.copy(alpha: backdrop.alpha * 0.4) ?? backdrop)
        context.setStrokeColor(border.copy(alpha: border.alpha * 0.5) ?? border)
        context.setLineWidth(0.5)
        context.drawPath(using: .fillStroke)
        drawMark(in: context)
        let textX = Self.textInset(for: font)
        let full = CTLineCreateWithAttributedString(content)
        let ellipsis = CTLineCreateWithAttributedString(token)
        let room = max(0, bounds.width - textX - 12)
        let line = CTLineCreateTruncatedLine(full, Double(room), .end, ellipsis) ?? full
        if selectedRange.location != NSNotFound {
            let start = CTLineGetOffsetForStringIndex(full, selectedRange.location, nil)
            let end = CTLineGetOffsetForStringIndex(full, selectedRange.location + selectedRange.length, nil)
            let rect = CGRect(x: textX + start - Self.chipPadding, y: 3,
                              width: end - start + 2 * Self.chipPadding, height: bounds.height - 6)
                .intersection(CGRect(x: textX - Self.chipPadding, y: 0,
                                     width: room + 2 * Self.chipPadding, height: bounds.height))
            if !rect.isNull {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                                       cornerHeight: rect.height / 2, transform: nil))
                context.setFillColor(chip)
                context.fillPath()
            }
        }
        context.saveGState()
        context.clip(to: CGRect(x: textX, y: 0, width: room, height: bounds.height))
        context.translateBy(x: textX, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The configured folder symbol, rebuilt only when its size or colour
    /// changes, not on every draw as the selection moves.
    private static var folderCache: (size: CGFloat, color: CGColor, image: NSImage)?
    private static func folderSymbol(size: CGFloat, color: CGColor) -> NSImage? {
        if let cache = folderCache, cache.size == size, cache.color == color { return cache.image }
        guard let image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)
                .applying(.init(paletteColors: [NSColor(cgColor: color) ?? .secondaryLabelColor]))) else { return nil }
        folderCache = (size, color, image)
        return image
    }

    /// A folder outline in the candidates' colour, centred on the row.
    private func drawMark(in context: CGContext) {
        let size = Self.markSize(for: font)
        guard let symbol = Self.folderSymbol(size: size * 0.8, color: mark) else { return }
        let fitted = symbol.size
        let rect = CGRect(x: Self.inset + (size - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                          width: fitted.width, height: fitted.height).integral
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
