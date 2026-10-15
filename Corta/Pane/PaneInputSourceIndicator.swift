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
import Carbon
import CortaTerminal

/// A pane-local input state presented in the window toolbar or prompt overlay.
/// No PTY writes, polling, timers or grid cells.
@MainActor final class PaneInputSourceIndicator {
    let view = InputSourceIndicatorView()
    private(set) var source: InputSourceState?
    private var notificationTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private(set) var automaticallyVisible = false
    var enabledSourcesProvider: () -> Bool = { SystemInputSource.hasRelevantEnabledSources() }
    private var placement = InputSourceIndicatorPlacement()
    var onChange: (() -> Void)?
    var sourceProvider: () -> InputSourceState? = { SystemInputSource.current() }

    init() {
        if !view.isHidden { view.isHidden = true }
    }

    isolated deinit { stop() }

    func start() {
        guard notificationTokens.isEmpty else { return }
        for name in [NSTextInputContext.keyboardSelectionDidChangeNotification,
            NSApplication.didBecomeActiveNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshSource() }
                })
        }
        let sourceNotifications: [CFString] = [kTISNotifySelectedKeyboardInputSourceChanged,
            kTISNotifyEnabledKeyboardInputSourcesChanged]
        for name in sourceNotifications {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshSource() }
                })
        }
        refreshSource()
    }

    func refreshSource() {
        let current = sourceProvider()
        let enabled = enabledSourcesProvider()
        guard current != source || enabled != automaticallyVisible else { return }
        source = current
        automaticallyVisible = enabled
        onChange?()
    }

    func stop() {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        distributedTokens.removeAll()
        if !view.isHidden { view.isHidden = true }
        placement.reset()
    }

    func update(grid: Grid, hasIntegration: Bool, promptRow: Int?, focused: Bool,
        scrollOffset: Int, configuration: Configuration, canvas: CanvasTextColors, cellSize: CGSize,
        topInset: CGFloat, compositionRect: CGRect?, blockedRects: [CGRect] = []) {
        guard let source, focused,
            configuration.inputSourceIndicator != .off,
            configuration.inputSourceIndicator != .auto || automaticallyVisible
        else {
            if !view.isHidden { view.isHidden = true }
            placement.reset()
            return
        }
        // The toolbar badge covers no output, so a running program — Claude
        // Code, an editor on the alternate screen — keeps it: that is where
        // people type in a second language too. Only the prompt-placed badge,
        // which sits on the grid, steps aside for them.
        let promptPlaced = configuration.inputSourceIndicatorPosition != .toolbar
        guard !promptPlaced || (scrollOffset == 0 && !grid.isAlternateScreenActive
            && (configuration.inputSourceIndicator == .always || !hasIntegration || promptRow != nil))
        else {
            if !view.isHidden { view.isHidden = true }
            placement.reset()
            return
        }
        if !promptPlaced {
            view.update(source: source, configuration: configuration, canvas: nil)
            let frame = CGRect(x: 0, y: 0, width: 28, height: 24)
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
            placement.reset()
            return
        }
        let size = CGSize(width: max(24, cellSize.width * 2 + 8), height: max(12, cellSize.height - 2))
        guard let row = placement.row(grid: grid, promptRow: promptRow,
            badgeColumns: Int(ceil((size.width + 4) / cellSize.width)), compositionRect: compositionRect,
            cellSize: cellSize, topInset: topInset) else {
            if !view.isHidden { view.isHidden = true }
            return }
        let rect = CGRect(x: TerminalLayout.insets.left + CGFloat(grid.columns) * cellSize.width - size.width,
            y: topInset + CGFloat(row) * cellSize.height + 1, width: size.width, height: size.height)
        guard !blockedRects.contains(where: { $0.intersects(rect) }) else {
            if !view.isHidden { view.isHidden = true }
            return }
        view.update(source: source, configuration: configuration, canvas: canvas)
        if view.frame != rect { view.frame = rect }
        if view.isHidden { view.isHidden = false }
    }
}

/// Placement advances only downward within one prompt, so editing an earlier
/// character cannot make the indicator chase the cursor or oscillate.
nonisolated struct InputSourceIndicatorPlacement {
    private var prompt: Int?
    private var minimumRow: Int?
    private var columns: Int?
    private var rows: Int?
    mutating func reset() { prompt = nil; minimumRow = nil; columns = nil; rows = nil }

    mutating func row(grid: Grid, promptRow: Int?, badgeColumns: Int,
        compositionRect: CGRect? = nil, cellSize: CGSize = .init(width: 8, height: 16),
        topInset: CGFloat = 0) -> Int? {
        let base = grid.scrollback.totalPushed
        let identity = promptRow ?? -1
        if prompt != identity || columns != grid.columns || rows != grid.rows {
            reset()
            prompt = identity
            columns = grid.columns
            rows = grid.rows
        }
        let first = promptRow.map { max(0, $0 - base) } ?? grid.cursor.row
        var row = max(first, max(grid.cursor.row, (minimumRow ?? (base + first)) - base))
        let startColumn = max(0, grid.columns - badgeColumns)
        while row < grid.rows {
            let line = grid.line(atAbsoluteRow: base + row)
            let occupied = (startColumn..<grid.columns).contains(where: { column in
                guard let cell = line?[column] else { return false }
                return cell.scalar != 0 && cell.scalar != 32
                    || cell.attributes.contains(.wideSpacer)
            })
            let cursorConflict = row == grid.cursor.row && grid.cursor.column >= startColumn
            let badgeRect = CGRect(x: TerminalLayout.insets.left + CGFloat(startColumn) * cellSize.width,
                y: topInset + CGFloat(row) * cellSize.height, width: CGFloat(badgeColumns) * cellSize.width,
                height: cellSize.height)
            if !occupied && !cursorConflict && compositionRect?.intersects(badgeRect) != true {
                minimumRow = base + row
                return row
            }
            row += 1
            minimumRow = base + row
        }
        return nil
    }
}

/// Quiet text with an optional subtle tint; mouse and selection pass through.
@MainActor final class InputSourceIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var source: InputSourceState?
    private var configuration = Configuration()
    /// The theme's colours when the badge sits on the canvas, beside the
    /// prompt; nil in the toolbar, which is window chrome and follows macOS.
    private var canvas: CanvasTextColors?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.alignment = .center
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("input-source-indicator")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = configuration.inputSourceIndicatorPosition == .toolbar ? bounds.height / 2 : 4
        let height = min(bounds.height, label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    func update(source: InputSourceState, configuration: Configuration, canvas: CanvasTextColors?) {
        guard self.source != source || self.configuration != configuration || self.canvas != canvas
        else { return }
        self.source = source
        self.configuration = configuration
        self.canvas = canvas
        label.stringValue = source.badge
        let description = source.kind == .unknown
            ? L10n.format("inputSource.unknown", source.name)
            : L10n.format("inputSource.current", source.name)
        toolTip = description
        setAccessibilityLabel(description)
        applyColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        guard let source else { return }
        // On the canvas, system colours resolve against the canvas's darkness;
        // in the toolbar the badge inherits the window's (#348).
        let wanted = canvas?.appearance
        if appearance?.name != wanted?.name { appearance = wanted }
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors(source) }
    }
    private func applyColors(_ source: InputSourceState) {
        let custom = source.kind == .direct ? configuration.inputSourceDirectColor : configuration.inputSourceIMEColor
        // Default presentation stays quiet. Explicit custom backgrounds retain
        // their original contrast-aware behavior.
        if custom.isEmpty || source.kind == .unknown {
            let tinted = source.kind == .ime || source.kind == .nonLatinLayout
            if let canvas, !tinted {
                // Direct input on the canvas: the theme's own text, faded, so
                // a theme darker or lighter than macOS still reads (#348).
                label.textColor = NSColor(cgColor: canvas.text(alpha: 0.65, contrastAlpha: 1))
                layer?.backgroundColor = canvas.text(alpha: 0.08, contrastAlpha: 0.12)
            } else {
                // The indigo of an IME mode stays its cue; resolved against the
                // canvas's appearance above, it is the variant that reads there.
                label.textColor = tinted ? .systemIndigo : .secondaryLabelColor
                layer?.backgroundColor = (tinted ? NSColor.systemIndigo : .secondaryLabelColor)
                    .withAlphaComponent(tinted && canvas != nil ? 0.16 : 0.08).cgColor
            }
            let increaseContrast = canvas?.increaseContrast ?? SystemAccessibility.increaseContrast
            layer?.borderWidth = increaseContrast ? 1 : 0
            layer?.borderColor = label.textColor?.withAlphaComponent(0.4).cgColor
            return
        }
        let system: NSColor = .controlBackgroundColor
        let background: NSColor
        if source.kind != .unknown, let c = Theme.color(custom) {
            background = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        } else { background = system }
        let rgb = background.usingColorSpace(.sRGB) ?? .gray
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        label.textColor = luminance > 0.179 ? .black : .white
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = (canvas?.increaseContrast ?? SystemAccessibility.increaseContrast) ? 1 : 0.5
        layer?.borderColor = label.textColor?.withAlphaComponent(0.35).cgColor
    }
}
