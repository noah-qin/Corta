import AppKit
import CortaTerminal
import Metal
import QuartzCore

/// An `NSView` backed by a `CAMetalLayer`, driven by `CADisplayLink`
/// (the current display-link API for this deployment target;
/// `CVDisplayLink` in the roadmap is descriptive, not prescriptive).
///
/// This file owns the layer, the display link and the frame tick. Input
/// lives in extensions by concern: `TerminalView+Keyboard.swift`,
/// `TerminalView+IME.swift` (Track A), `TerminalView+Mouse.swift` and
/// `TerminalView+Scroll.swift` (Track C).
final class TerminalView: NSView, CALayerDelegate {
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?
    /// Mouse-moved tracking for ⌘-hover link feedback (M4.6); `.inVisibleRect`
    /// keeps it glued to the visible area across resizes.
    private var mouseTrackingArea: NSTrackingArea?
    /// The transient confirmation in the pane's bottom-right corner
    /// (`showToast`), and the work item that takes it away again. Stored so a
    /// second toast replaces the first instead of stacking on top of it —
    /// copy-on-select fires once per drag, and a user selecting three things
    /// in a row must not end up with three overlapping labels.
    private var toastLayer: CALayer?
    private var toastDismissal: DispatchWorkItem?

    // Accessibility (`TerminalView+Accessibility.swift`). Storage lives here
    // because extensions cannot add their own.

    /// The pane's answer to "what does this terminal say" — text, cursor and
    /// selection, flattened. Installed by `ViewController`, like every other
    /// closure hook here, so the view needs no knowledge of `Grid`.
    var accessibilitySnapshotProvider: (() -> TerminalAccessibilitySnapshot?)?
    /// One cell's rect in this view's coordinates, so VoiceOver's cursor can
    /// be drawn around the characters it is reading.
    var accessibilityCellFrameProvider: ((_ row: Int, _ column: Int) -> CGRect)?
    var cachedAccessibilitySnapshot: TerminalAccessibilitySnapshot?
    var cachedAccessibilitySnapshotTime: CFTimeInterval = 0
    var lastAccessibilityPost: CFTimeInterval = 0

    /// Called once per frame, on the main thread, with the drawable's render
    /// pass descriptor and pixel size. `nil` drawable (window occluded,
    /// zero-size layer) means the frame is silently skipped.
    var onRenderFrame: ((MTLRenderPassDescriptor, CGSize, CAMetalDrawable) -> Void)?

    /// Asked before each vsync's drawable is acquired; a `false` answer
    /// skips the frame entirely — no drawable, no command buffer, no present
    /// — and parks the display link until `setNeedsRedraw()` is called, so a
    /// static screen does not even pay for the vsync wakeups (`PERFORMANCE.md`
    /// §3: idle CPU ~0%). The check must happen *before* `nextDrawable()`:
    /// an acquired drawable that is never presented is not recycled, so
    /// acquiring one per skipped frame would exhaust the pool and block the
    /// main thread.
    var shouldRenderFrame: (() -> Bool)?

    /// Called with raw bytes to write to the PTY for one key event.
    var onKeyBytes: (([UInt8]) -> Void)?

    /// Called for a scroll gesture, a page key or ⌘↑/⌘↓ (`M1.20`).
    var onScroll: ((ScrollGesture) -> Void)?

    /// Called for a paste request — ⌘V or the Edit menu's Paste. Reading the
    /// pasteboard, sanitising and warning is the shell's job
    /// (`SECURITY.md` §2.3).
    var onPaste: (() -> Void)?

    /// M4.4 search shortcuts and Escape-while-searching, offered before
    /// anything else in `keyDown`: Esc must dismiss the search bar rather
    /// than send a raw ESC byte to the child while it's open, and ⌘F/⌘G/
    /// ⇧⌘G must not fall through to `deliverBytes`. Returns whether the
    /// event was handled; `false` (or `nil`) continues the normal routing.
    var onSearchKey: ((NSEvent) -> Bool)?

    /// Called when a live window resize ends, so the shell can deliver the
    /// final size to the child without waiting out the debounce (M2.9).
    var onLiveResizeEnded: (() -> Void)?

    /// Called when the view becomes first responder — click-to-focus, the
    /// ⌘⌥ focus-move shortcuts, a split, a close all arrive here — so the
    /// split controller can track which pane owns input (M5.2).
    var onFocus: (() -> Void)?

    /// LNM (`CSI 20 h`) — while set, Return sends CR LF. Read per key event
    /// for the same reason as the kitty flags below: a program can change it
    /// at any point and the next keystroke has to honour the new value.
    var isNewLineMode: (() -> Bool)?

    /// M6.9 — the kitty keyboard protocol flags the child has asked for.
    /// Read per key event rather than cached: a program can change them at
    /// any point, and the next keystroke has to honour the new value.
    var keyboardEnhancements: (() -> KeyboardEnhancementFlags)?

    /// M6.15 — file paths dropped on the pane, already resolved to
    /// filesystem paths. The controller quotes and sends them.
    var onDropPaths: (([String]) -> Void)?
    /// The word under a force touch and where to anchor the dictionary
    /// popover, in this view's coordinates.
    var onLookUp: ((CGPoint) -> (String, CGPoint)?)?
    /// The current selection as text, for the Services menu, or nil when
    /// nothing is selected.
    var onServicesSelection: (() -> String?)?
    /// Text a service returned, to be sent to the child like a paste.
    var onServicesInsert: ((String) -> Void)?

    /// M6.14 — the trackpad magnification gesture. The controller spends it
    /// in whole font-size steps; the view only forwards it, like every other
    /// input here.
    var onMagnify: ((CGFloat) -> Void)?
    /// The magnification gesture ended, so the unspent remainder is dropped.
    var onMagnifyEnded: (() -> Void)?

    /// The window's backing scale factor changed — the view moved to a
    /// display with a different pixel density. The renderer's glyph atlas is
    /// rasterised per scale and has to be rebuilt.
    var onBackingScaleChange: ((CGFloat) -> Void)?

    /// The pane's controller, found by walking the responder chain (the view
    /// → its controller → the split controller). With splits the pane is no
    /// longer the window's content view controller, so `contentViewController`
    /// cannot find it anymore.
    var paneController: ViewController? {
        sequence(first: self as NSResponder, next: { $0.nextResponder })
            .first { $0 is ViewController } as? ViewController
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    // Stored state for the extension files — extensions cannot add storage.
    // The methods using these live in `TerminalView+Mouse.swift` and
    // `TerminalView+Scroll.swift`.

    /// Whether the child application has asked for mouse reports; the shell
    /// answers from the core's mode flags. When off, mouse events keep their
    /// normal meaning (scrolling the scrollback).
    var isMouseReportingEnabled: (() -> Bool)?

    /// Called with the SGR report bytes for one mouse event.
    var onMouseBytes: (([UInt8]) -> Void)?

    /// Set by the shell from the renderer's metrics; needed to turn a view
    /// point into a cell.
    var cellSize: CGSize = .zero

    /// The cursor cell's rect in this view's coordinates, answered by the
    /// shell (it owns the session, the insets and the metrics). Track A's
    /// IME layer (`TerminalView+IME.swift`) positions the candidate window
    /// and the preedit overlay from it; nil means the cursor is not
    /// currently knowable or visible.
    var cursorRectProvider: (() -> CGRect?)?

    /// The font the preedit overlay draws marked text with, answered by the
    /// shell so it tracks the renderer's font stack and current size
    /// (⌘=/⌘-). Nil leaves the overlay on its default.
    var preeditFontProvider: (() -> NSFont)?

    /// The point→cell mapping SGR mouse reports use, answered by the shell —
    /// it owns the content insets, the bottom-anchored grid origin and the
    /// grid size. A raw divide of the view point by the cell size is off by
    /// the insets (roughly one column and two rows at the defaults).
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
        // Order matters, and getting it wrong is silent. A layer-HOSTING view
        // is made by assigning `layer` first and only then setting
        // `wantsLayer`. The other order makes the view layer-BACKED: AppKit
        // creates and owns a backing layer, and the CAMetalLayer assigned
        // afterwards never joins the compositing tree.
        layer = metalLayer
        wantsLayer = true
        metalLayer.delegate = self
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = QuadRenderer.pixelFormat
        // Tag the drawable sRGB. Untagged, its contents are interpreted in
        // the display's own space — Display P3 on this hardware — so every
        // sRGB value the palette and the escape sequences specify rendered
        // oversaturated, and nothing matched what Terminal.app drew from the
        // same bytes. The pixel format stays `.bgra8Unorm` rather than
        // `_srgb` so no implicit linearisation happens on write; the values
        // are already sRGB-encoded (see `QuadRenderer`).
        metalLayer.framebufferOnly = true
        // Double buffering, opt-in for measurement.
        //
        // `maximumDrawableCount = 2` is often cited as removing a frame of
        // latency: with three drawables in flight a present can sit behind
        // two others, and with two it cannot. It can equally *add* latency,
        // because `nextDrawable()` then blocks the main thread more often
        // waiting for one to be recycled — and which of the two happens
        // depends on how long a frame takes on the machine in question, so
        // it is a question to measure rather than a value to pick.
        //
        // Corta ships the default (3) because that is what has been measured
        // (M6.12: 45.5 ms). This variable exists so the comparison can be run
        // as two launches of the same binary rather than as a code change —
        // an A/B where the only difference is the flag. Pair it with an
        // `os_signpost` trace (`InputLatencySignposts`): if double buffering
        // is costing rather than saving, it shows up as the `frame` interval
        // growing at its front, where `nextDrawable` waits.
        //
        // An environment variable and not a config key: this is a measurement
        // harness, not a setting anybody should be tuning, and a key nobody
        // should set is a row `docs/CONFIGURATION.md` should not have to
        // carry (`CLAUDE.md`). Same reasoning as `CORTA_RESTORE_WINDOWS`.
        if let raw = ProcessInfo.processInfo.environment["CORTA_MAX_DRAWABLES"],
            let count = Int(raw), (2...3).contains(count)
        {
            metalLayer.maximumDrawableCount = count
        }
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = false
        // A layer-hosting view is not clipped by the window's rounded
        // corners, so the drawable paints square corners past the frame.
        // Because the view is flipped, the hosted layer's MinY corners are
        // its *top* corners — the mask rounds the window's two top corners
        // and the window itself rounds the bottom. In a split, though, only
        // a pane that actually touches a top corner may round it: the same
        // mask on an interior pane cuts a visible notch out of the divider
        // junction. `layout()` recomputes the mask from the pane's position
        // in the window (M5).
        metalLayer.cornerRadius = 10
        metalLayer.maskedCorners = []
        metalLayer.masksToBounds = true
        registerForFileDrags()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        guard let window else {
            displayLink = nil
            return
        }
        let link = window.displayLink(target: self, selector: #selector(frameTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        updateExteriorCornerMask()
        positionToast()
    }

    /// Moving between displays of different backing scales — Retina to an
    /// external 1x panel and back — changes the drawable's pixel density.
    /// The glyph atlas is rasterised for one scale (`TerminalRenderer.init`),
    /// so without this the glyphs keep the old density and the text goes
    /// soft on the new display.
    /// AppKit delivers a pinch as a stream of `magnify:` events carrying
    /// the *delta* since the last one, then a phase-ended event. Both halves
    /// matter: without the end, the next pinch inherits this one's unspent
    /// remainder and jumps.
    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
        if event.phase == .ended || event.phase == .cancelled { onMagnifyEnded?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        if let window { onBackingScaleChange?(window.backingScaleFactor) }
    }

    /// Rounds only the window's top corners this pane actually touches (see
    /// `commonInit`); interior panes get no mask, so divider junctions stay
    /// square.
    private func updateExteriorCornerMask() {
        guard let window else {
            metalLayer.maskedCorners = []
            return
        }
        // Window base coordinates are y-up; with `.fullSizeContentView` the
        // content spans the whole frame, so the window's top is its height.
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

    /// Wakes the parked display link; the next vsync asks
    /// `shouldRenderFrame`. Main thread only, like everything on a view.
    func setNeedsRedraw() {
        displayLink?.isPaused = false
    }

    /// Renders and presents one frame immediately, if one is due. Used to
    /// paint before the window is ordered on screen: the window's
    /// background is transparent until the Metal layer has presented, so
    /// without this every new window and every new tab flashes whatever is
    /// behind it for a frame or two.
    func drawNow() {
        updateDrawableSize()
        frameTick()
    }

    /// The default visual bell (M4.8): a brief flash of the terminal
    /// surface. A transient screen effect, not a persistent panel, so it
    /// draws directly on the Metal layer rather than adding a glass surface.
    func flashBell() {
        // Reduce Motion, on a *flash*, cannot mean "no animation": a bell
        // whose whole expression is a 0.18 s fade would silently stop
        // signalling anything at zero duration. It means "no movement" — so
        // the flash stays and is simply held steady for the same span before
        // being removed, which is what the setting actually asks for.
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

    /// The bell as a held wash rather than a fade — same layer, same colour,
    /// same duration, no animated property.
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

    /// A short-lived label in the pane's bottom-right corner — "Copied", and
    /// anything else that is worth confirming but not worth a dialog.
    ///
    /// This exists because copy-on-select is now on by default. Copying
    /// silently was the whole argument against that default: the clipboard
    /// changes under the user with nothing to show for it. A confirmation
    /// they can ignore is the smallest thing that answers it.
    ///
    /// A `CALayer`, not a subview: this view is layer-*hosting* (see
    /// `commonInit`), so its layer tree is the only place to put a decoration
    /// — the same reason `flashBell` is drawn this way. Nothing here touches
    /// the Metal drawable, so a toast never costs the render loop a frame.
    /// `kind` decides the symbol and the fill. The symbol is the point: a
    /// toast that distinguished "copied" from "the shell could not start" by
    /// blue against amber would distinguish them for nobody who cannot
    /// separate those two hues, and the words alone are easy to miss in the
    /// corner of a screen full of text. Icon *and* word *and* colour, in that
    /// order of importance.
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
            // Blue, and deliberately not one of the theme's colours: the
            // toast has to be legible over whatever the terminal is showing
            // under it, and a colour taken from the palette would be the one
            // element that vanishes exactly when the theme is low-contrast or
            // when a program has painted that colour across the screen.
            // `systemBlue` rather than `controlAccentColor` for the same
            // reason — the accent colour is the user's and can be grey.
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
        // A little lift, so the capsule reads as sitting above the text
        // rather than as a coloured run inside it.
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

        // Held on the main queue rather than a `Timer`: the view may go away
        // with the pane, and a cancelled work item leaves nothing behind.
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

    /// Bottom-right, inside the same inset the text grid uses so it lines up
    /// with the content rather than with the pane edge. The hosted layer's
    /// geometry runs top-down with the flipped view (see `commonInit`), so
    /// "bottom" is `maxY`. Re-run from `layout()`: a pane resized while a
    /// toast is up must not leave it stranded mid-air.
    private func positionToast() {
        guard let capsule = toastLayer else { return }
        let size = capsule.bounds.size
        CATransaction.begin()
        // No implicit animation: this is a correction, not a move.
        CATransaction.setDisableActions(true)
        capsule.position = CGPoint(
            x: bounds.maxX - size.width - TerminalLayout.insets.right,
            y: bounds.maxY - size.height - TerminalLayout.insets.bottom)
        CATransaction.commit()
    }

    /// Long enough to read four words without looking for it, short enough
    /// that it is gone before it becomes something to dismiss.
    private static let toastDuration: TimeInterval = 1.1
    private static let toastPadding = CGSize(width: 10, height: 5)

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @objc private func frameTick() {
        let frameInterval = InputLatencySignposts.begin(.frame)
        defer { InputLatencySignposts.end(.frame, frameInterval) }
        if let shouldRenderFrame, !shouldRenderFrame() {
            // Nothing to draw: park the link. The shell un-parks it via
            // `setNeedsRedraw()` when output arrives or the viewport changes.
            displayLink?.isPaused = true
            return
        }
        guard let drawable = metalLayer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        let bg = TerminalColorPalette.clearColor
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(bg.x), Double(bg.y), Double(bg.z), Double(bg.w))
        pass.colorAttachments[0].storeAction = .store
        onRenderFrame?(pass, metalLayer.drawableSize, drawable)
    }
}

/// One scroll input, already resolved to what it means for the scrollback
/// viewport — the shell decides how far `.lines` clamps against actual
/// history, and how many lines one `.page` is (it knows the cell height);
/// this type doesn't know the scrollback depth or the font metrics.
enum ScrollGesture {
    /// A relative line delta; positive scrolls back into history.
    case lines(Int)
    case page(up: Bool)
    case toTop
    case toBottom
}
