import AppKit
import Metal
import QuartzCore

/// An `NSView` backed by a `CAMetalLayer`, driven by `CADisplayLink`
/// (the current display-link API for this deployment target;
/// `CVDisplayLink` in the roadmap is descriptive, not prescriptive).
///
/// Keyboard input is translated to bytes and written straight to the PTY —
/// **not** routed through `interpretKeyEvents:`. That path exists for text
/// input and IME composition (M3's job); using it now would swallow control
/// keys the shell needs verbatim (`ROADMAP.md` M1.18).
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
        metalLayer.isOpaque = true
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
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        onRenderFrame?(pass, metalLayer.drawableSize, drawable)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if let gesture = Self.scrollGesture(for: event) {
            onScroll?(gesture)
            return
        }
        if Self.isPasteShortcut(event) {
            onPaste?()
            return
        }
        guard let bytes = Self.bytes(for: event) else {
            super.keyDown(with: event)
            return
        }
        onKeyBytes?(bytes)
    }

    /// ⌘V — checked before `bytes(for:)`, which would otherwise deliver a
    /// bare "v" to the child.
    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// The Edit menu's Paste item lands here; ⌘V arrives via `keyDown`.
    /// (`paste(_:)` comes from `NSStandardKeyBindingProviding`, so it is not
    /// an `NSResponder` override.)
    func paste(_ sender: Any?) {
        onPaste?()
    }

    // MARK: - Mouse reporting (M2.7, SGR ?1006)

    /// Whether the child application has asked for mouse reports; the shell
    /// answers from the core's mode flags. When off, mouse events keep their
    /// normal meaning (scrolling the scrollback).
    var isMouseReportingEnabled: (() -> Bool)?

    /// Called with the SGR report bytes for one mouse event.
    var onMouseBytes: (([UInt8]) -> Void)?

    /// Set by the shell from the renderer's metrics; needed to turn a view
    /// point into a cell.
    var cellSize: CGSize = .zero

    override func mouseDown(with event: NSEvent) {
        guard report(event, phase: .press(.left)) else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.left)) else { super.mouseUp(with: event); return }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard report(event, phase: .press(.right)) else { super.rightMouseDown(with: event); return }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.right)) else { super.rightMouseUp(with: event); return }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard report(event, phase: .press(.middle)) else { super.otherMouseDown(with: event); return }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.middle)) else { super.otherMouseUp(with: event); return }
    }

    private enum MousePhase {
        case press(SGRMouse.Button)
        case release(SGRMouse.Button)
    }

    /// Sends the SGR report for one event; returns false when mouse reporting
    /// is off and the event should follow its normal path.
    private func report(_ event: NSEvent, phase: MousePhase) -> Bool {
        guard isMouseReportingEnabled?() == true, cellSize.width > 0, cellSize.height > 0
        else { return false }
        let (column, row) = cellUnder(event)
        let modifiers = Self.mouseModifiers(of: event)
        let bytes: [UInt8]
        switch phase {
        case .press(let button):
            bytes = SGRMouse.press(button: button, column: column, row: row, modifiers: modifiers)
        case .release(let button):
            bytes = SGRMouse.release(button: button, column: column, row: row, modifiers: modifiers)
        }
        onMouseBytes?(bytes)
        return true
    }

    /// The cell under the event, in grid coordinates.
    private func cellUnder(_ event: NSEvent) -> (column: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return SGRMouse.cell(for: point, cellWidth: cellSize.width, cellHeight: cellSize.height)
    }

    static func mouseModifiers(of event: NSEvent) -> SGRMouse.Modifiers {
        var modifiers = SGRMouse.Modifiers()
        modifiers.shift = event.modifierFlags.contains(.shift)
        modifiers.meta = event.modifierFlags.contains(.option)
        modifiers.control = event.modifierFlags.contains(.control)
        return modifiers
    }

    /// ⌘↑ / ⌘↓ jump to the top and bottom of scrollback, the same gesture
    /// most terminals and pagers use — checked before `bytes(for:)` so a
    /// held ⌘ never leaks an arrow escape sequence to the child.
    static func scrollGesture(for event: NSEvent) -> ScrollGesture? {
        guard event.modifierFlags.contains(.command) else { return nil }
        switch event.specialKey {
        case .some(.upArrow): return .toTop
        case .some(.downArrow): return .toBottom
        default: return nil
        }
    }

    /// Translates one key event directly to the bytes a real terminal would
    /// send. Control combinations map to C0 codes; arrows and a handful of
    /// editing keys map to the xterm CSI sequences `$TERM=xterm-256color`
    /// promises (`DESIGN.md` §2.5).
    static func bytes(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags

        switch event.specialKey {
        case .some(.upArrow): return escape("A")
        case .some(.downArrow): return escape("B")
        case .some(.rightArrow): return escape("C")
        case .some(.leftArrow): return escape("D")
        case .some(.home): return escape("H")
        case .some(.end): return escape("F")
        case .some(.deleteForward): return [0x1B, 0x5B, 0x33, 0x7E]  // ESC [ 3 ~
        default: break
        }

        if flags.contains(.control), let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        {
            // Ctrl+letter -> C0 control code; the classic (scalar & 0x1F).
            let value = scalar.value
            if (0x40...0x7E).contains(value) {
                return [UInt8(value & 0x1F)]
            }
        }

        guard let characters = event.characters, !characters.isEmpty else { return nil }
        // Return sends CR, not LF — the pty's line discipline turns that
        // into whatever the child's terminal driver expects.
        if characters == "\r" || characters == "\n" { return [0x0D] }
        return Array(characters.utf8)
    }

    private static func escape(_ final: String) -> [UInt8] {
        Array("\u{1B}[\(final)".utf8)
    }

    // MARK: - Scrolling (M1.20)

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        // With mouse reporting on, the wheel belongs to the child (SGR 64/65
        // per notch), not to the scrollback.
        if isMouseReportingEnabled?() == true, cellSize.width > 0, cellSize.height > 0 {
            let (column, row) = cellUnder(event)
            onMouseBytes?(
                SGRMouse.wheel(
                    up: event.scrollingDeltaY > 0, column: column, row: row,
                    modifiers: Self.mouseModifiers(of: event)))
            return
        }
        // Natural or not, up-scroll (content moves down, deltaY negative in
        // AppKit's convention for a flipped view scrolling content upward)
        // reveals older lines — one line per ~10pt, which feels right for a
        // trackpad's momentum scroll without a config knob.
        let lines = Int((-event.scrollingDeltaY / 10).rounded())
        guard lines != 0 else { return }
        onScroll?(.lines(lines))
    }

    override func scrollPageUp(_ sender: Any?) { onScroll?(.page(up: true)) }
    override func scrollPageDown(_ sender: Any?) { onScroll?(.page(up: false)) }
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
