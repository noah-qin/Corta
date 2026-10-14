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

/// Native overlays live in the margin and beside the caret, never in terminal cells.
/// The command-status rules themselves are drawn by `TerminalRenderer`, with
/// the text they belong to (#238); this view keeps only their tooltips.
final class ShellOverlayView: NSView {
    struct Status: Equatable {
        var rect: CGRect
        var description: String
    }
    var statuses: [Status] = []
    var completion: DirectoryCompletion?
    /// Preedit and directory hints share the caret. Keep shell refreshes
    /// from recreating a hint underneath the input method's native overlay.
    var isInputComposing = false {
        didSet { if isInputComposing { hideCompletion() } }
    }
    fileprivate struct CompletionPresentation: Equatable {
        var state: DirectoryCompletion?
        var anchor: CGRect
        var bounds: CGRect
        var font: NSFont
        var baseline: CGFloat
        var composing: Bool
        /// A theme, appearance or contrast change must redraw a hint
        /// already showing.
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var increaseContrast: Bool
    }
    private var lastCompletionPresentation: CompletionPresentation?
    private var preview: DirectoryGhostView?
    private var candidateRow: DirectoryCandidateRowView?
    /// Native completion previews occupy space outside the terminal grid.
    var occupiedRects: [CGRect] { subviews.filter { !$0.isHidden }.map(\.frame) }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateStatuses(_ rows: [Status]) {
        guard statuses != rows else { return }
        statuses = rows
        removeAllToolTips()
        for row in rows { addToolTip(row.rect.insetBy(dx: -3, dy: 0), owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        statuses.first { $0.rect.insetBy(dx: -3, dy: 0).contains(point) }?.description ?? ""
    }

    func showCompletion(_ state: DirectoryCompletion?, anchor: CGRect,
        font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular), baseline: CGFloat = 12) {
        // Once per frame, not a lock per colour.
        let variant = TerminalColorPalette.activeVariant
        let presentation = CompletionPresentation(
            state: state, anchor: anchor, bounds: bounds,
            font: font, baseline: baseline, composing: isInputComposing,
            foreground: variant.foreground, background: variant.background,
            increaseContrast: SystemAccessibility.increaseContrast)
        guard lastCompletionPresentation != presentation else { return }
        lastCompletionPresentation = presentation
        guard !isInputComposing, let state, let suffix = state.previewSuffix, !suffix.isEmpty else {
            completion = nil
            preview?.removeFromSuperview()
            preview = nil
            candidateRow?.removeFromSuperview()
            candidateRow = nil
            return
        }
        completion = state
        let colors = HintColors(presentation)
        if !state.typedPrefix.isEmpty {
            let ghost = preview ?? DirectoryGhostView()
            ghost.text = suffix
            ghost.font = font
            ghost.color = colors.muted
            ghost.baseline = baseline
            ghost.frame = CGRect(x: anchor.minX, y: anchor.minY,
                width: max(0, bounds.width - TerminalLayout.insets.right - anchor.minX), height: anchor.height)
            ghost.toolTip = L10n.text("completion.hint")
            if preview == nil { addSubview(ghost)
                preview = ghost }
            ghost.needsDisplay = true
        } else {
            preview?.removeFromSuperview()
            preview = nil
        }
        // Once the prefix resolves to one folder, the inline suffix is enough.
        guard state.typedPrefix.isEmpty || state.candidates.count > 1 else {
            candidateRow?.removeFromSuperview()
            candidateRow = nil
            return
        }
        let row = candidateRow ?? DirectoryCandidateRowView()
        let prefixWidth = (state.typedPrefix as NSString).size(withAttributes: [.font: font]).width
        let x = max(TerminalLayout.insets.left, anchor.minX - prefixWidth)
        let below = anchor.maxY + 3
        let fitsBelow = below + anchor.height <= bounds.height - TerminalLayout.insets.bottom
        // At the bottom, the temporary hint sits above the prompt instead.
        row.frame = CGRect(x: x, y: fitsBelow ? below : max(0, anchor.minY - anchor.height - 3),
            width: max(0, bounds.width - TerminalLayout.insets.right - x), height: anchor.height)
        row.baseline = baseline
        row.backdrop = fitsBelow ? nil : colors.backdrop
        row.update(state: state, font: font, colors: colors)
        row.toolTip = L10n.text("completion.hint")
        if candidateRow == nil { addSubview(row)
            candidateRow = row }
        row.needsDisplay = true
    }

    func hideCompletion() { showCompletion(nil, anchor: .zero) }

    /// The renderer's text colour, faded: the theme's, built-in or from the
    /// config file, never the system label colour, which follows macOS
    /// appearance and was black on a forced-dark canvas (#346). Increase
    /// Contrast strengthens both, as it promotes secondary labels elsewhere.
    fileprivate struct HintColors {
        var muted: CGColor
        var selected: CGColor
        var backdrop: CGColor

        init(_ presentation: CompletionPresentation) {
            func srgb(_ color: SIMD4<Float>, alpha: CGFloat) -> CGColor {
                CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y),
                    blue: CGFloat(color.z), alpha: alpha)
            }
            let contrast = presentation.increaseContrast
            muted = srgb(presentation.foreground, alpha: contrast ? 0.7 : 0.35)
            selected = srgb(presentation.foreground, alpha: contrast ? 1 : 0.65)
            backdrop = srgb(presentation.background, alpha: 1)
        }
    }
}

/// CoreText uses the renderer's font and baseline, so the suggestion reads as
/// part of the command line. It remains outside the grid and copied text.
private final class DirectoryGhostView: NSView {
    var text = ""
    var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var baseline: CGFloat = 12
    var color = CGColor(gray: 0.5, alpha: 0.35)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityIdentifier() -> String { "directory-completion-preview" }

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

/// A quiet, single-line set of alternatives. Selection is conveyed by stronger
/// text and an underline, with no panel chrome or focusable controls.
private final class DirectoryCandidateRowView: NSView {
    private var content = NSAttributedString(string: "")
    private var token = NSAttributedString(string: "…")
    private var visibleText = ""
    var baseline: CGFloat = 12
    /// The canvas colour, when the row sits over output above the prompt.
    var backdrop: CGColor?
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
        let available = max(0, bounds.width - width("…    …"))
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
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.muted]
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
        if let backdrop {
            context.setFillColor(backdrop)
            context.fill(bounds)
        }
        let full = CTLineCreateWithAttributedString(content)
        let ellipsis = CTLineCreateWithAttributedString(token)
        let line = CTLineCreateTruncatedLine(full, Double(bounds.width), .end, ellipsis) ?? full
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
