//
//  ViewController.swift
//  Corta
//
//  Created by Noah on 9/1/26.
//

import Cocoa
import CoreText
import CortaTerminal
import Metal
import Synchronization

/// Owns one `TerminalSession` and the `TerminalRenderer`/`TerminalView` that
/// draw it — the unit a split (M5) will multiply, not a global (`DESIGN.md`
/// §2.4).
///
/// This file owns lifecycle, the session and the render loop. Behaviour
/// lives in extensions by concern: `ViewController+Input.swift` (Track A),
/// `ViewController+Selection.swift` (Track C) and
/// `ViewController+Commands.swift` (Track D).
class ViewController: NSViewController {
    private var terminalView: TerminalView!
    // Not `private`: the extension files (`+Input`, `+Selection`) reach
    // these, and extensions cannot add their own storage.
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    private var commandQueue: MTLCommandQueue!
    var scrollOffset = 0
    /// The current text selection, owned by `ViewController+Selection.swift`
    /// (Track C) and read by the render loop. Stored here because extensions
    /// cannot add storage.
    var selection: TerminalSelection?
    private var didSizeWindow = false
    /// Set by layout changes the damage diff cannot see (drawable size,
    /// backing scale) and by local actions that change what is drawn without
    /// touching the grid (scrolling); consumed by `updateDamage`.
    private var needsRedraw = true
    /// Set from the reader thread's `onOutput` (every parse batch); the
    /// vsync gate checks this one flag and only snapshots and diffs the grid
    /// when it is set, so a truly idle frame costs a boolean check rather
    /// than a line-by-line comparison.
    private let outputPending = Mutex(false)
    /// Coalesces `session.resize` during a live drag (M2.9); the last size
    /// actually requested, so no-op layouts don't re-send the same winsize.
    private var resizeDebouncer: ResizeDebouncer!
    private var lastRequestedSize: TerminalSize?

    /// The drag is over — the child should see the final size now, not after
    /// the debounce window expires. Wired to `TerminalView`'s
    /// `viewDidEndLiveResize` (live-resize notifications live on the view).
    func endLiveResize() {
        resizeDebouncer.flush()
    }

    /// Initial and minimum grid sizes. The window's content size is derived
    /// from these and the font's cell metrics, never from hardcoded points,
    /// so it follows a font or size change.
    private let defaultColumns = 120
    private let defaultRows = 30
    /// Breathing room between the grid and the window edge, in points. The
    /// grid used to start at x=0, which clipped the left column's glyphs
    /// against the window frame.
    ///
    /// The top is larger because the window uses `.fullSizeContentView`: the
    /// background runs the full height so there is no seam at the titlebar,
    /// and the grid starts below where the traffic lights sit.
    static let titlebarHeight: CGFloat = 28
    /// Matches the window's own curvature so the glass and the drawable end
    /// on the same arc.
    static let windowCornerRadius: CGFloat = 12
    static let contentInsets = NSEdgeInsets(
        top: 8 + titlebarHeight, left: 10, bottom: 8, right: 10)
    static var insetWidth: CGFloat { contentInsets.left + contentInsets.right }
    static var insetHeight: CGFloat { contentInsets.top + contentInsets.bottom }

    private let minimumColumns = 20
    private let minimumRows = 5

    override func viewDidLoad() {
        super.viewDidLoad()

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        terminalRenderer = try! TerminalRenderer(device: device, font: font, scale: scale)
        commandQueue = device.makeCommandQueue()

        let metrics = terminalRenderer.pointMetrics
        let contentSize = NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth + Self.insetWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight + Self.insetHeight)
        // Size the container to the target content size *before* the first
        // layout. Otherwise the storyboard's 480x270 produces a transient
        // 53x15 session, the shell's early output is laid out against that,
        // and growing the window afterwards leaves that output stranded in
        // the top half with fifteen blank rows below it.
        self.view.setFrameSize(contentSize)

        let view = TerminalView(frame: NSRect(origin: .zero, size: contentSize))
        // Deliberately no autoresizing mask. The mask applies the superview's
        // resize *delta*, and this view is born at the target content size
        // while the storyboard's view is still its own smaller size. The
        // `setContentSize` in `viewDidAppear` then grew the superview by
        // (240, 138) and the mask added that delta on top of a view already
        // at the target — leaving it 960x546 inside a 720x408 superview.
        //
        // In AppKit's bottom-left coordinates the overflow sits above the
        // visible content, so row 0 — the only row with anything on it in a
        // fresh shell — was drawn entirely inside the clipped strip and the
        // window looked black. `viewDidLayout` sets the frame outright.
        // Liquid Glass (macOS 26). `NSGlassEffectView` embeds its content in
        // the system's glass material — the refraction, blur and specular
        // response are the platform's, not a blur we approximate. The
        // terminal draws its background translucent on top so the glass
        // reads through it; an alpha over an unblurred desktop is just a
        // dimmer desktop.
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Self.windowCornerRadius
        // Tinted toward the terminal's own background so the glass stays a
        // dark surface whatever is behind the window.
        glass.tintColor = NSColor(srgbRed: 40 / 255, green: 42 / 255, blue: 47 / 255, alpha: 1)
        glass.contentView = view
        glass.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(glass)
        // Constraints, not a frame set from a layout callback. The view is
        // born at the target content size while the storyboard's view is
        // still its own smaller size, and `viewDidAppear`'s `setContentSize`
        // then grows the superview — but a frame assigned in `viewDidLayout`
        // only tracks if that callback runs again afterwards, which it did
        // not: the view stayed 480x270 inside a 1080x510 superview, so the
        // drawable was half size and the grid came out 53x15 instead of
        // 120x30. AppKit maintains constraints regardless of callback order.
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            glass.topAnchor.constraint(equalTo: self.view.topAnchor),
            glass.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        terminalView = view

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let initialSize = TerminalSize(rows: UInt16(defaultRows), columns: UInt16(defaultColumns))
        session = try! TerminalSession(
            executable: shell, arguments: ["-l"],
            // Launched from Finder the app inherits "/" as its working
            // directory, so the shell opened in the filesystem root. A
            // terminal should start where a login shell would.
            size: initialSize, workingDirectory: NSHomeDirectory())
        lastRequestedSize = initialSize
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session.resize(to: size)
        }
        // Fires on the reader thread after every parse batch.
        session.onOutput = { [weak self] in
            self?.noteOutput()
        }

        view.onRenderFrame = { [weak self] pass, drawableSize, drawable in
            self?.render(into: pass, drawableSize: drawableSize, drawable: drawable)
        }
        view.shouldRenderFrame = { [weak self] in
            self?.updateDamage() ?? false
        }
        view.onKeyBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        view.onScroll = { [weak self] gesture in
            self?.scroll(gesture)
        }
        view.onLiveResizeEnded = { [weak self] in
            self?.endLiveResize()
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
        view.cellSize = CGSize(width: terminalRenderer.pointMetrics.cellWidth, height: terminalRenderer.pointMetrics.cellHeight)
        view.isMouseReportingEnabled = { [weak self] in
            self?.mouseReportingEnabled() ?? false
        }
        view.onMouseBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        // Track A's IME layer positions the candidate window and the preedit
        // overlay from this: the cursor cell's rect in view coordinates,
        // derived here where the insets and metrics live.
        view.cursorRectProvider = { [weak self] in
            guard let self, let terminalRenderer, session != nil else { return nil }
            let metrics = terminalRenderer.pointMetrics
            let cursor = session.snapshot().cursor
            return CGRect(
                x: Self.contentInsets.left + CGFloat(cursor.column) * metrics.cellWidth,
                y: Self.contentInsets.top + CGFloat(cursor.row) * metrics.cellHeight,
                width: metrics.cellWidth, height: metrics.cellHeight)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSizeWindow, let window = view.window else { return }
        didSizeWindow = true
        let metrics = terminalRenderer.pointMetrics
        // Dragging snaps to whole cells, so a resize never leaves a partial
        // row or column.
        window.title = "Corta"
        // A terminal is a dark surface whatever the system appearance is.
        // Following the system turned the glass light and washed the grey
        // background out with it.
        window.appearance = NSAppearance(named: .darkAqua)
        // Content runs the full height with a transparent titlebar, so the
        // background is one continuous surface instead of a titlebar butted
        // against a differently-shaded grid.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // The Metal layer clears to a translucent colour; the window has to
        // stop painting its own opaque background for that to show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + Self.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + Self.insetHeight)
        window.setContentSize(NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth + Self.insetWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight + Self.insetHeight))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Layout can change the drawable's size or backing scale without any
        // grid change the damage diff would notice — force one frame.
        invalidateDisplay()
        resizeSessionToFitView()
    }

    /// Runs at vsync before a drawable is acquired. Cheap path: nothing
    /// arrived and nothing local changed, so no snapshot, no diff, no frame —
    /// and the display link parks itself (`TerminalView.frameTick`), which is
    /// what lets a static screen idle at ~0% CPU (`PERFORMANCE.md` §3). When
    /// output did arrive, the snapshot is diffed against the renderer's
    /// line-granular cache and the frame happens only on damage.
    private func updateDamage() -> Bool {
        let hasOutput = outputPending.withLock { pending -> Bool in
            let was = pending
            pending = false
            return was
        }
        guard needsRedraw || hasOutput else { return false }
        let forced = needsRedraw
        needsRedraw = false
        let grid = session.snapshot()
        // The rebuilt rows land in the renderer's cache; `render` diffs once
        // more when it draws and picks up anything that arrived since.
        let damaged = terminalRenderer.updateInstances(
            grid: grid, scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0, selection: selection)
        return forced || damaged
    }

    /// Called from the reader thread after each parse batch: record that the
    /// grid may have changed and wake the (possibly parked) display link.
    nonisolated private func noteOutput() {
        outputPending.withLock { $0 = true }
        Task { @MainActor [weak self] in
            self?.terminalView.setNeedsRedraw()
        }
    }

    /// Marks the display dirty and wakes the display link — for local changes
    /// (layout, scrolling) that produce no PTY output.
    func invalidateDisplay() {
        needsRedraw = true
        terminalView.setNeedsRedraw()
    }

    private func resizeSessionToFitView() {
        // Nothing reaches the child until `viewDidAppear` has settled the
        // window. The storyboard lays out at the content-layout height first
        // (the frame less the titlebar) and only reaches full height once
        // `.fullSizeContentView` applies, so an early layout produced a
        // 28-row session that the shell laid its first output out against,
        // stranding two blank rows under the prompt once the grid grew to 30.
        // The session is constructed at the target size already.
        guard didSizeWindow, session != nil, let terminalRenderer else { return }
        let usable = CGSize(
            width: view.bounds.width - Self.insetWidth,
            height: view.bounds.height - Self.insetHeight)
        let columns = UInt16(max(1, usable.width / terminalRenderer.pointMetrics.cellWidth))
        let rows = UInt16(max(1, usable.height / terminalRenderer.pointMetrics.cellHeight))
        let size = TerminalSize(rows: rows, columns: columns)
        guard size != lastRequestedSize else { return }
        lastRequestedSize = size
        // During a live drag, coalesce; otherwise (initial layout,
        // programmatic resize) deliver immediately.
        resizeDebouncer.resize(to: size, coalesce: view.window?.inLiveResize ?? false)
    }

    /// Runs at vsync, on the main thread — reads the latest grid without
    /// ever blocking the reader thread (`PERFORMANCE.md` §2.1).
    private func render(
        into renderPassDescriptor: MTLRenderPassDescriptor, drawableSize: CGSize, drawable: CAMetalDrawable
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let grid = session.snapshot()
        terminalRenderer.render(
            grid: grid, scrollOffset: scrollOffset,
            rect: Self.contentRect(
                in: drawableSize, scale: terminalRenderer.scale,
                gridHeight: CGFloat(grid.rows) * terminalRenderer.metrics.cellHeight),
            drawableSize: drawableSize,
            cursorVisible: scrollOffset == 0, selection: selection,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The grid's rectangle inside the drawable, in pixels.
    ///
    /// Pixel space has its origin at the drawable's top-left
    /// (`Shaders.metal`). The grid is anchored to the *bottom*: rounding rows
    /// down leaves a remainder, and at the bottom that reads as a gap under
    /// the prompt — the one place a terminal's spacing gets noticed. At the
    /// top it lands in the titlebar band instead.
    static func contentRect(
        in drawableSize: CGSize, scale: CGFloat, gridHeight: CGFloat
    ) -> CGRect {
        let bottom = drawableSize.height - contentInsets.bottom * scale
        return CGRect(
            x: contentInsets.left * scale,
            y: max(contentInsets.top * scale, bottom - gridHeight),
            width: max(0, drawableSize.width - insetWidth * scale),
            height: gridHeight)
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }
}
