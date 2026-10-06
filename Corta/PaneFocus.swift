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
import CortaTerminal

/// What a pane's focus indicators need from the pane.
protocol PaneFocusHost: AnyObject {
    var view: NSView { get }
    var session: TerminalSession! { get }
    var splitController: SplitViewController? { get }
    var isFocusedPane: Bool { get }
    var scrollOffset: Int { get }
    var didTeardown: Bool { get }
    var inputSourceIndicator: PaneInputSourceIndicator { get }
    /// How far the window's chrome reaches over the pane's top edge.
    var chromeOverlap: CGFloat { get }
    func invalidateDisplay()
}

/// How a pane shows, and reports, that it has the keyboard: the dim over an
/// unfocused split pane, the ring and highlight on the focused one, the
/// blinking cursor only the focused pane draws, and focus reporting
/// (`?1004`): `CSI I` / `CSI O`, which Neovim's `autoread` and tmux's
/// `focus-events` rely on. Focused means this pane holds the keyboard and
/// its window is key.
final class PaneFocus: NSObject {
    weak var host: PaneFocusHost?

    /// Dims unfocused panes; never intercepts input (`PassthroughView`).
    private(set) var dimView: NSView?
    /// On `hasUserFocus`, not `isFocusedPane`: hidden when the window resigns
    /// key, like the ring — neither claims where the keyboard *would* go.
    private(set) var highlightView: NSView?
    /// The positive focus signal, so unfocused panes need not look disabled.
    private(set) var ringView: NSView?
    /// Re-tensioned every layout, so a top pane's ring clears a tab bar that
    /// appears, hides or is dragged out.
    private var ringTopConstraint: NSLayoutConstraint?
    /// `nil` until the first `?1004` report, so it always goes out.
    private(set) var lastReportedFocus: Bool?
    private var isObservingWindows = false

    private var cursorBlinkTimer: Timer?
    /// False for the off half of a blink.
    private(set) var cursorBlinkVisible = true
    private var lastBlinkCursor: Cursor?
    private var lastBlinkStyle: CursorStyle?

    init(host: PaneFocusHost? = nil) {
        self.host = host
    }

    /// Focused means this pane holds the keyboard and its window is key.
    var hasUserFocus: Bool {
        guard let host else { return false }
        return host.isFocusedPane && (host.view.window?.isKeyWindow ?? false)
    }

    // MARK: - Views

    /// Adds the dim, highlight and ring over `view`'s content, replacing any
    /// from a previous setup.
    func installViews(in view: NSView) {
        removeViews()
        let dim = Self.overlay(in: view)
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.unfocusedDim).cgColor
        dimView = dim

        let highlight = Self.overlay(in: view)
        highlight.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(Self.focusHighlightAlpha).cgColor
        highlightView = highlight

        let ring = PassthroughView()
        ring.wantsLayer = true
        ring.layer?.borderWidth = Self.focusRingWidth
        ring.layer?.cornerRadius = TerminalLayout.windowCornerRadius
        ring.layer?.borderColor = Self.focusRingColor.cgColor
        ring.isHidden = true
        ring.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ring)
        let ringTop = ring.topAnchor.constraint(
            equalTo: view.topAnchor, constant: Self.focusRingWidth / 2)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Self.focusRingWidth / 2),
            ring.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Self.focusRingWidth / 2),
            ringTop,
            ring.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -Self.focusRingWidth / 2),
        ])
        ringTopConstraint = ringTop
        ringView = ring
    }

    func removeViews() {
        for view in [dimView, highlightView, ringView] { view?.removeFromSuperview() }
        dimView = nil
        highlightView = nil
        ringView = nil
        ringTopConstraint = nil
    }

    /// A hidden, full-size layer-backed view that lets input through.
    private static func overlay(in view: NSView) -> NSView {
        let overlay = PassthroughView()
        overlay.wantsLayer = true
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return overlay
    }

    /// Tab bar changes are all layout passes, so the pane's `viewDidLayout`
    /// suffices.
    func updateLayout() {
        guard let host, let ring = ringView else { return }
        ringTopConstraint?.constant = host.chromeOverlap + Self.focusRingWidth / 2
        // Only corners that are the window's, as `TerminalView` does for the
        // drawable; the pane's view is not flipped, so `MaxY` is the top.
        guard let window = host.view.window else { return }
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: host.view.convert(host.view.bounds, to: nil),
            windowSize: window.frame.size)
        var mask: CACornerMask = []
        if edges.top && edges.left { mask.insert(.layerMinXMaxYCorner) }
        if edges.top && edges.right { mask.insert(.layerMaxXMaxYCorner) }
        ring.layer?.maskedCorners = mask
    }

    /// The indicators for the pane's focus now, and the report to the child.
    func applyAppearance() {
        guard let host else { return }
        // One pane needs neither.
        let inSplit = host.splitController?.hasMultiplePanes == true
        // The dim is structural and stays while the app is inactive; ring and
        // highlight follow `hasUserFocus`, so cmd-tab leaves no false ring.
        dimView?.isHidden = host.isFocusedPane || !inSplit
        let highlighted = hasUserFocus && inSplit
        ringView?.isHidden = !highlighted
        highlightView?.isHidden = !highlighted
        // The accent can change at runtime; Increase Contrast wants more.
        ringView?.layer?.borderColor = Self.focusRingColor.cgColor
        ringView?.layer?.borderWidth =
            SystemAccessibility.increaseContrast ? Self.focusRingWidth + 1 : Self.focusRingWidth
        reportIfNeeded()
        if !hasUserFocus {
            stopCursorBlink()
            host.inputSourceIndicator.view.isHidden = true
        } else {
            host.inputSourceIndicator.refreshSource()
        }
        host.invalidateDisplay()
    }

    /// Enough to tell panes apart, little enough to read through.
    static let unfocusedDim: CGFloat = 0.08
    /// A hairline; 2pt dominated small windows.
    static let focusRingWidth: CGFloat = 1
    /// Half-strength accent — full alpha was louder than the text it framed;
    /// full again under Increase Contrast.
    static var focusRingColor: NSColor {
        let accent = NSColor.controlAccentColor
        return SystemAccessibility.increaseContrast
            ? accent : accent.withAlphaComponent(focusRingAlpha)
    }

    static let focusRingAlpha: CGFloat = 0.5
    /// Stronger recoloured the text underneath.
    static let focusHighlightAlpha: CGFloat = 0.05

    // MARK: - Focus reporting

    private static let focusIn: [UInt8] = [0x1B, 0x5B, 0x49]  // CSI I
    private static let focusOut: [UInt8] = [0x1B, 0x5B, 0x4F]  // CSI O

    /// Reports only real changes; AppKit's key and responder churn would
    /// otherwise stream reports. Two fixed byte strings, no stream text
    /// (`SECURITY.md` §2.1).
    func reportIfNeeded() {
        let focused = hasUserFocus
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        // A failed pane (no Metal 4, no shell) has no session to report to.
        guard let session = host?.session, session.isFocusReportingEnabled else { return }
        session.write(focused ? Self.focusIn : Self.focusOut)
    }

    /// Filtered to this pane's window, or every pane reports every window.
    func observeWindows() {
        guard !isObservingWindows else { return }
        isObservingWindows = true
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowFocusChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowFocusChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === host?.view.window else { return }
        reportIfNeeded()
        // Cmd-Tab drops the ring even though the focused pane doesn't change.
        applyAppearance()
    }

    /// The pane closed.
    func stop() {
        stopCursorBlink()
        NotificationCenter.default.removeObserver(self)
        isObservingWindows = false
    }

    // MARK: - Cursor blink

    /// The program's explicit shape (`DECSCUSR`) beats the configured one.
    func effectiveCursorStyle(grid: Grid) -> CursorStyle {
        if grid.cursorStyleIsExplicit { return grid.cursorStyle }
        let config = ConfigurationStore.shared.configuration
        return config.cursorShape.style(blinking: config.cursorBlink)
    }

    private var canBlinkCursor: Bool {
        guard let host else { return false }
        return !host.didTeardown && hasUserFocus && host.scrollOffset == 0
            && host.view.window?.occlusionState.contains(.visible) == true
    }

    func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkVisible = true
    }

    /// Per frame: a blinking style blinks while it may, and a moved cursor,
    /// a changed style or new output restarts it visible.
    func updateCursorBlink(grid: Grid, style: CursorStyle, reset: Bool) {
        let blinking = style == .blinkingBlock || style == .blinkingBar || style == .blinkingUnderline
        // A hidden cursor (`?25l`) has nothing to blink: no 2 Hz redraws.
        guard blinking && canBlinkCursor && grid.isCursorVisible else {
            stopCursorBlink()
            return
        }
        if reset || lastBlinkCursor != grid.cursor || lastBlinkStyle != style {
            stopCursorBlink()
        }
        lastBlinkCursor = grid.cursor
        lastBlinkStyle = style
        guard cursorBlinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canBlinkCursor else {
                    self.stopCursorBlink()
                    return
                }
                self.cursorBlinkVisible.toggle()
                self.host?.invalidateDisplay()
            }
        }
        timer.tolerance = 0.05
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Input falls through to the terminal view.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
