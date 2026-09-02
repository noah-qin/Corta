import AppKit
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

    /// Called when a live window resize ends, so the shell can deliver the
    /// final size to the child without waiting out the debounce (M2.9).
    var onLiveResizeEnded: (() -> Void)?

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
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        // A layer-hosting view is not clipped by the window's rounded
        // corners, so the drawable painted square corners past the frame.
        // Round the two bottom corners to match; the titlebar covers the top.
        metalLayer.cornerRadius = 10
        metalLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        metalLayer.masksToBounds = true
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
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnded?()
    }

    /// Wakes the parked display link; the next vsync asks
    /// `shouldRenderFrame`. Main thread only, like everything on a view.
    func setNeedsRedraw() {
        displayLink?.isPaused = false
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @objc private func frameTick() {
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
