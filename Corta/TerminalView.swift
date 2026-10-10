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
import Metal
import QuartzCore

/// An `NSView` hosting a `CAMetalLayer`. This file owns the layer and the
/// drawable size; `FrameScheduler` owns the display link, and input lives
/// in the `TerminalView+Keyboard/IME/Mouse/Scroll` extensions.
final class TerminalView: NSView, CALayerDelegate {
    private let metalLayer = CAMetalLayer()
    private lazy var frameScheduler = FrameScheduler(metalLayer: metalLayer)
    /// Recreated with `frameScheduler` on each `viewDidMoveToWindow`: it
    /// observes one window's key state, so a stale instance would stop
    /// tracking focus after a tab moves windows. Not `private` because
    /// `TerminalView+Scroll.swift` reports gesture phases to it.
    var renderPolicy: RenderPolicy?
    /// Pauses rendering while the window is occluded; replaced when changing windows.
    private var occlusionObserver: NSObjectProtocol?
    /// Mouse-moved tracking for ⌘-hover link feedback; `.inVisibleRect`
    /// keeps it glued to the visible area across resizes.
    private var mouseTrackingArea: NSTrackingArea?
    /// The toast (`showToast`) and its dismissal; stored so a second toast
    /// replaces the first rather than stacking.
    private var toastLayer: CALayer?
    private var toastDismissal: DispatchWorkItem?

    // Accessibility (`TerminalView+Accessibility.swift`); extensions cannot
    // add storage.

    /// Text, cursor and selection, flattened; installed by `ViewController` so
    /// the view needs no knowledge of `Grid`.
    var accessibilitySnapshotProvider: (() -> TerminalAccessibilitySnapshot?)?
    /// One cell's rect in view coordinates, for VoiceOver's cursor.
    var accessibilityCellFrameProvider: ((_ row: Int, _ column: Int) -> CGRect)?
    var cachedAccessibilitySnapshot: TerminalAccessibilitySnapshot?
    var cachedAccessibilitySnapshotTime: CFTimeInterval = 0
    var lastAccessibilityPost: CFTimeInterval = 0
    /// The trailing `valueChanged` post owed inside the rate-limit interval.
    var pendingAccessibilityPost: DispatchWorkItem?

    /// Called once per accepted frame on the main thread; forwarded to
    /// `frameScheduler`.
    var onRenderFrame: ((CGSize, CAMetalDrawable) -> Bool)? {
        get { frameScheduler.onRenderFrame }
        set { frameScheduler.onRenderFrame = newValue }
    }

    /// Does the per-frame prepare/diff work and reports whether anything is
    /// still pending; `false` lets the scheduler pause, keeping idle CPU near
    /// zero (`PERFORMANCE.md` §3). Forwarded to `frameScheduler`.
    var shouldRenderFrame: (() -> Bool)? {
        get { frameScheduler.shouldRenderFrame }
        set { frameScheduler.shouldRenderFrame = newValue }
    }

    var onKeyBytes: (([UInt8]) -> Void)?
    /// The key event the input context is handling right now: set around
    /// `handleEvent`, so a command the IME answers it with is encoded from
    /// the key itself (`doCommand(by:)`).
    var keyEventInInputContext: NSEvent?
    /// Keys whose press reached the child, so a kitty release report is
    /// never sent for a press something else consumed (the search bar's
    /// Escape, an IME composition).
    var keyCodesDelivered: Set<UInt16> = []

    var onScroll: ((ScrollGesture) -> Void)?

    /// A paste request; reading, sanitising and warning is the controller's
    /// job (`SECURITY.md` §2.3).
    var onPaste: (() -> Void)?

    /// Search shortcuts, offered first in `keyDown`: while the bar is open Esc
    /// must dismiss it rather than reach the child. Returns whether the event
    /// was handled. ⌘G / ⇧⌘G are fixed menu items with no `bind.` key.
    var onSearchKey: ((NSEvent) -> Bool)?
    var onCompletionKey: ((NSEvent) -> Bool)?
    let shellOverlay = ShellOverlayView()
    var onInputContextChange: (() -> Void)?
    var inputCompositionRect: CGRect?

    /// A live resize ended; deliver the final size without the debounce.
    var onLiveResizeEnded: (() -> Void)?

    /// The view became first responder, by any route; the split controller
    /// tracks the focused pane from this.
    var onFocus: (() -> Void)?

    // Mode and config closures below are read per key event: a program or a
    // config edit can change them at any point, and the next keystroke must
    // honour it.

    /// LNM (`CSI 20 h`): Return sends CR LF.
    var isNewLineMode: (() -> Bool)?

    var keyboardEnhancements: (() -> KeyboardEnhancementFlags)?

    /// DECCKM (`CSI ? 1 h`): cursor keys send SS3 forms.
    var applicationCursorKeys: (() -> Bool)?

    /// DECKPAM (`ESC =`): the keypad sends SS3 forms.
    var applicationKeypad: (() -> Bool)?

    /// ⌥ as Meta (ESC prefix) rather than composing.
    var optionAsMeta: (() -> Bool)?

    /// The shortcut table in force. Keys `keyDown` handles itself (paste,
    /// scrollback jumps) match against it, never a literal.
    var keybindings: (() -> Keybindings)?

    /// Dropped file paths; the controller sanitises, quotes and sends them.
    var onDropPaths: (([String]) -> Void)?
    /// The word under a force touch and the popover anchor.
    var onLookUp: ((CGPoint) -> (String, CGPoint)?)?
    /// The selection as text for the Services menu.
    var onServicesSelection: (() -> String?)?
    /// Text a service returned, sent like a sanitised paste.
    var onServicesInsert: ((String) -> Void)?

    /// Pinch deltas; the controller spends them in whole font-size steps.
    var onMagnify: ((CGFloat) -> Void)?
    /// The pinch ended; the unspent remainder is dropped.
    var onMagnifyEnded: (() -> Void)?

    /// The backing scale changed; the glyph atlas must be re-rasterised.
    var onBackingScaleChange: ((CGFloat) -> Void)?

    /// The drawable resized; the damage diff can't see that (the grid is
    /// unchanged), so the frame is forced from here.
    var onDrawableSizeChange: (() -> Void)?

    /// The pane's controller, via the responder chain — with splits it is not
    /// the window's `contentViewController`.
    var paneController: ViewController? {
        sequence(first: self as NSResponder, next: { $0.nextResponder })
            .first { $0 is ViewController } as? ViewController
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(); onInputContextChange?() }
        return accepted
    }

    // Storage for `TerminalView+Mouse.swift` and `TerminalView+Scroll.swift`.

    /// Whether the child asked for mouse reports; when off, the mouse scrolls
    /// the scrollback.
    var isMouseReportingEnabled: (() -> Bool)?
    var mouseTrackingMode: (() -> MouseTrackingMode)?
    var mouseOverrideModifier: Configuration.MouseOverrideModifier = .option
    var reportedMouseButtons: Set<Int> = []
    var lastMouseReportCell: (column: Int, row: Int)?
    var didShowMouseOverrideHint = false

    var onMouseBytes: (([UInt8]) -> Void)?

    /// From the renderer's metrics.
    var cellSize: CGSize = .zero

    /// The cursor cell's rect in view coordinates, for the IME candidate
    /// window and preedit overlay; nil when not visible.
    var cursorRectProvider: (() -> CGRect?)?

    /// The preedit font, tracking the renderer's font and ⌘= size.
    var preeditFontProvider: (() -> NSFont)?

    /// Point to cell for SGR mouse reports. The shell owns the insets and the
    /// bottom-anchored origin; a raw divide is off by about a column and two
    /// rows.
    var cellAtPoint: ((CGPoint) -> (column: Int, row: Int))?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Order matters, silently: assigning `layer` before `wantsLayer` makes a
        // layer-hosting view. The reverse makes it layer-backed, and the
        // CAMetalLayer never joins the compositing tree.
        layer = metalLayer
        wantsLayer = true
        metalLayer.delegate = self
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = QuadPipelineCache.pixelFormat
        // Tag the drawable sRGB; untagged it is read as Display P3 and every
        // colour renders oversaturated. `.bgra8Unorm`, not `_srgb`: the values
        // are already sRGB-encoded (see `QuadPipelineCache`).
        metalLayer.framebufferOnly = true
        // Double buffering, opt-in for measurement. Two drawables can save a
        // frame of latency or add it (`nextDrawable` blocks more), depending on
        // the machine; the default 3 is what was measured (`PERFORMANCE.md`
        // §5.7). This lets the A/B be two launches of one binary, traced with
        // `InputLatencySignposts`. An environment variable, not a config key:
        // nobody should tune it (D10).
        if let count = DiagnosticsEnvironment.maxDrawables() {
            metalLayer.maximumDrawableCount = count
        }
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Opaque, like the window: the canvas is content, not glass, and the
        // compositor need not blend it. Until a frame lands, and around a
        // resize, the layer's own colour shows — the theme's, never what is
        // behind the window.
        metalLayer.isOpaque = true
        applyCanvasBackground()
        // A hosted layer isn't clipped by the window's rounded corners. The view
        // is flipped, so MinY corners are the top ones; `layout()` rounds only the
        // corners this pane touches, or an interior pane notches the divider.
        metalLayer.cornerRadius = 10
        metalLayer.maskedCorners = []
        metalLayer.masksToBounds = true
        // No implicit geometry animations: on a zoom or fullscreen transition
        // Core Animation would scale the previous frame with the bounds, and the
        // text visibly grows then snaps back. What the layer shows until the
        // next frame is `layerContentsPlacement`'s job, below.
        metalLayer.actions = [
            "bounds": NSNull(), "position": NSNull(), "contents": NSNull(),
            "contentsScale": NSNull(), "cornerRadius": NSNull(),
        ]
        // Through AppKit, not the layer: AppKit owns `contentsGravity` for a
        // layer-hosting view and overwrites it (measured). The default
        // `.scaleAxesIndependently` stretched the last frame during a zoom;
        // `.topLeft` holds it at true size.
        layerContentsPlacement = .topLeft
        // The drawable is the content; the view never redraws itself.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForFileDrags()
    }

    /// Tears the display link down for a pane that is closing. A closed
    /// window keeps its views, so `viewDidMoveToWindow` never sees `nil`:
    /// without this the link stays on the main run loop, and the run loop
    /// keeps the layer, this view and the whole pane alive.
    var isRendering: Bool { frameScheduler.isAttached }

    func stopRendering() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        renderPolicy = nil
        frameScheduler.attach(to: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        frameScheduler.attach(to: window)
        renderPolicy = nil
        guard let window else { return }
        updateDrawableSize()
        renderPolicy = RenderPolicy(scheduler: frameScheduler, window: window)
        // Pause rendering while occluded. The PTY reader keeps draining
        // (`PERFORMANCE.md` §2.1), so a hidden pane's output waits, not lost.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusionState() }
        }
        updateOcclusionState()
    }

    private func updateOcclusionState() {
        guard let window else { return }
        if window.occlusionState.contains(.visible) {
            frameScheduler.resume()
        } else {
            frameScheduler.isPaused = true
        }
    }

    isolated deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        updateExteriorCornerMask()
        positionToast()
    }

    /// A pinch arrives as deltas, then a phase end; without the end, the next
    /// pinch inherits this one's remainder and jumps.
    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
        if event.phase == .ended || event.phase == .cancelled { onMagnifyEnded?() }
    }

    /// A display with another backing scale needs the glyph atlas
    /// re-rasterised, or the text goes soft.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        if let window { onBackingScaleChange?(window.backingScaleFactor) }
    }

    /// Rounds only the window top corners this pane touches (see
    /// `commonInit`).
    private func updateExteriorCornerMask() {
        guard let window else {
            metalLayer.maskedCorners = []
            return
        }
        // Window coordinates are y-up and the content spans the frame.
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: convert(bounds, to: nil), windowSize: window.frame.size)
        var mask: CACornerMask = []
        // The hosted layer is flipped: MinY is the top.
        if edges.top && edges.left { mask.insert(.layerMinXMinYCorner) }
        if edges.top && edges.right { mask.insert(.layerMaxXMinYCorner) }
        metalLayer.maskedCorners = mask
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnded?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea { removeTrackingArea(mouseTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    /// Wakes the parked scheduler; main thread only.
    func setNeedsRedraw() {
        frameScheduler.resume()
    }

    func renderEchoOnDemand() -> Bool { frameScheduler.renderEchoOnDemand() }

    /// Shared input hook, independent of diagnostic sampling.
    func noteUserInput() {
        frameScheduler.noteInput()
        renderPolicy?.noteInput()
    }

    /// Starts a keypress-to-glass sample (`RenderMetrics`); a frame that
    /// never reached the glass wakes this pane for another.
    func noteKeystrokeForMetrics(at timestamp: TimeInterval) {
        guard RenderMetrics.isEnabled else { return }
        RenderMetrics.noteKeystroke(at: timestamp) { [weak self] in
            DispatchQueue.main.async { self?.setNeedsRedraw() }
        }
    }

    /// Sizes the drawable for the current bounds and asks for a frame.
    /// Returns immediately; the frame lands on the next vsync.
    func drawNow() {
        updateDrawableSize()
        frameScheduler.resume()
    }

    /// The theme's background on the layer itself, shown before the first
    /// frame and wherever the drawable has not caught up. On setup and on
    /// every theme or appearance change.
    func applyCanvasBackground() {
        let bg = TerminalColorPalette.defaultBackground
        metalLayer.backgroundColor = CGColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1)
    }

    /// The visual bell, drawn on the layer.
    func flashBell() {
        // Reduce Motion means no movement, not no signal: hold the flash steady
        // for the same span instead of fading.
        if SystemAccessibility.reduceMotion {
            flashBellWithoutMotion()
            return
        }
        let flash = CALayer()
        flash.frame = bounds
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        flash.cornerRadius = metalLayer.cornerRadius
        flash.maskedCorners = metalLayer.maskedCorners
        layer?.addSublayer(flash)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        flash.add(fade, forKey: "flash")
        CATransaction.commit()
    }

    private func flashBellWithoutMotion() {
        let flash = CALayer()
        flash.frame = bounds
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        flash.cornerRadius = metalLayer.cornerRadius
        flash.maskedCorners = metalLayer.maskedCorners
        layer?.addSublayer(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            flash.removeFromSuperlayer()
        }
    }

    // MARK: - Transient confirmation

    /// A short-lived label in the pane's bottom-right corner ("Copied"),
    /// mainly so copy-on-select is never silent.
    ///
    /// A `CALayer`, since this view is layer-hosting; it never costs the
    /// Metal render loop a frame. `kind` sets symbol and fill: icon, word and
    /// colour, in that order, so hue is never the only signal.
    enum ToastKind {
        case confirmation
        case warning

        var symbolName: String {
            switch self {
            case .confirmation: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var fill: NSColor {
            switch self {
            // Not a theme colour, which could vanish into the screen; not
            // `controlAccentColor`, which can be grey.
            case .confirmation: NSColor.systemBlue.withAlphaComponent(0.92)
            case .warning: NSColor.systemOrange.withAlphaComponent(0.94)
            }
        }
    }

    func showToast(_ text: String, kind: ToastKind = .confirmation) {
        toastDismissal?.cancel()
        toastLayer?.removeFromSuperlayer()

        let scale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let label = CATextLayer()
        label.string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.white])
        label.contentsScale = scale
        label.alignmentMode = .left

        let symbolSide = (font.pointSize + 3).rounded(.up)
        let symbolGap: CGFloat = 5
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(
            width: (textSize.width).rounded(.up) + symbolSide + symbolGap
                + 2 * Self.toastPadding.width,
            height: max(symbolSide, textSize.height.rounded(.up))
                + 2 * Self.toastPadding.height)

        let capsule = CALayer()
        capsule.bounds = CGRect(origin: .zero, size: size)
        capsule.anchorPoint = .zero
        capsule.cornerRadius = size.height / 2
        capsule.contentsScale = scale
        capsule.backgroundColor = kind.fill.cgColor
        capsule.borderColor = NSColor.white.withAlphaComponent(
            SystemAccessibility.increaseContrast ? 0.85 : 0.22
        ).cgColor
        capsule.borderWidth = 1
        capsule.shadowColor = NSColor.black.cgColor
        capsule.shadowOpacity = 0.28
        capsule.shadowRadius = 6
        capsule.shadowOffset = CGSize(width: 0, height: 1)
        if let symbol = NSImage(
            systemSymbolName: kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: font.pointSize + 1, weight: .semibold)
                    .applying(.init(paletteColors: [.white])))
        {
            let icon = CALayer()
            icon.frame = CGRect(
                x: Self.toastPadding.width,
                y: ((size.height - symbolSide) / 2).rounded(),
                width: symbolSide, height: symbolSide)
            icon.contentsScale = scale
            icon.contents = symbol.layerContents(forContentsScale: scale)
            icon.contentsGravity = .resizeAspect
            capsule.addSublayer(icon)
        }
        label.frame = CGRect(
            x: Self.toastPadding.width + symbolSide + symbolGap,
            y: (size.height - textSize.height).rounded() / 2,
            width: textSize.width.rounded(.up) + 1, height: textSize.height.rounded(.up))
        capsule.addSublayer(label)

        layer?.addSublayer(capsule)
        toastLayer = capsule
        positionToast()

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0.0
        appear.toValue = 1.0
        appear.duration = SystemAccessibility.duration(0.12)
        capsule.add(appear, forKey: "appear")

        // A cancellable work item leaves nothing behind if the pane goes.
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissToast() }
        toastDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: dismissal)
    }

    private func dismissToast() {
        guard let capsule = toastLayer else { return }
        toastLayer = nil
        toastDismissal = nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = SystemAccessibility.duration(0.25)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { capsule.removeFromSuperlayer() }
        capsule.opacity = 0
        capsule.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Bottom-right inside the text inset; flipped, so bottom is `maxY`.
    /// Re-run from `layout()` so a resize never strands it.
    private func positionToast() {
        guard let capsule = toastLayer else { return }
        let size = capsule.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.position = CGPoint(
            x: bounds.maxX - size.width - TerminalLayout.insets.right,
            y: bounds.maxY - size.height - TerminalLayout.insets.bottom)
        CATransaction.commit()
    }

    private static let toastDuration: TimeInterval = 1.1
    private static let toastPadding = CGSize(width: 10, height: 5)

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard metalLayer.contentsScale != scale || metalLayer.drawableSize != size else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        // A resized drawable holds a stale frame, and the unchanged grid gives
        // the damage diff nothing to report; ask for a frame.
        onDrawableSizeChange?()
    }

}

/// One scroll input for the scrollback viewport; the controller clamps
/// `.lines` and sizes `.page`.
enum ScrollGesture {
    /// A relative line delta; positive scrolls back into history.
    case lines(Int)
    case page(up: Bool)
    case toTop
    case toBottom
}
