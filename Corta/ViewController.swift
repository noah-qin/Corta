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
    // Not `private`: the extension files (`+Input`, `+Selection`, `+Commands`)
    // reach these, and extensions cannot add their own storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    private var commandQueue: MTLCommandQueue!
    /// Kept so `ViewController+Commands` can rebuild the renderer (with a new
    /// font size) without going through `MTLCreateSystemDefaultDevice` again.
    var device: MTLDevice!
    /// The font's point size; ⌘+/⌘−/⌘0 change it (`ViewController+Commands`).
    /// The atlas is rasterised for one size, so a change rebuilds the
    /// renderer — see `setFontSize`.
    var fontSize: CGFloat = ViewController.defaultFontSize
    static let defaultFontSize: CGFloat = 14
    var scrollOffset = 0
    /// The current text selection, owned by `ViewController+Selection.swift`
    /// (Track C) and read by the render loop. Stored here because extensions
    /// cannot add storage.
    var selection: TerminalSelection?
    var didSizeWindow = false
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
    /// The last grid size sent (or about to be sent) to the child; ⌘+/⌘−
    /// re-fit the window to keep this grid size at the new cell metrics.
    var lastRequestedSize: TerminalSize?

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
    let minimumColumns = 20
    let minimumRows = 5

    override func viewDidLoad() {
        super.viewDidLoad()

        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }
        self.device = device
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        terminalRenderer = try! TerminalRenderer(device: device, font: font, scale: scale)
        commandQueue = device.makeCommandQueue()

        let metrics = terminalRenderer.pointMetrics
        let contentSize = NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight + TerminalLayout.insetHeight)
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
        glass.cornerRadius = TerminalLayout.windowCornerRadius
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
                x: TerminalLayout.insets.left + CGFloat(cursor.column) * metrics.cellWidth,
                y: TerminalLayout.insets.top + CGFloat(cursor.row) * metrics.cellHeight,
                width: metrics.cellWidth, height: metrics.cellHeight)
        }
        // SGR mouse reports name an on-screen cell, so they need the same
        // inset-aware, bottom-anchored mapping as selection hit-testing
        // (`documentPosition`) — a raw divide of the view point by the cell
        // size reports a cell off by the insets. scrollOffset is 0 here:
        // the report is about what is on screen, not the document.
        view.cellAtPoint = { [weak self] point in
            guard let self, let terminalRenderer, session != nil, let terminalView
            else { return (column: 0, row: 0) }
            let grid = session.snapshot()
            let position = Self.documentPosition(
                for: point, viewHeight: terminalView.bounds.height,
                metrics: terminalRenderer.pointMetrics, grid: grid, scrollOffset: 0)
            return (position.column, position.row)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
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
        // against a differently-shaded grid. This is `viewWillAppear`, not
        // `viewDidAppear`, for a reason: the style mask must be final before
        // the window's first layout. When it was applied in `viewDidAppear`
        // the first layout ran at the content-rect height (frame minus
        // titlebar), and `resizeSessionToFitView` — already ungated by then —
        // delivered a transient 28-row winsize to the child, then 30 once the
        // full height arrived. The shrink-then-grow strands two blank rows
        // under the prompt of anything the child printed in between.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // The Metal layer clears to a translucent colour; the window has to
        // stop painting its own opaque background for that to show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + TerminalLayout.insetHeight)
        window.setContentSize(NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight + TerminalLayout.insetHeight))
        // Nothing else claims first responder, and without one the view
        // hierarchy — the terminal view, this controller — is not in the
        // responder chain at all: keyDown never fires and menu actions
        // targeting First Responder (⌘V, ⌘=) dispatch from the window down,
        // past the controller. The terminal view is where keys belong.
        window.makeFirstResponder(terminalView)
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
        // Nothing reaches the child until `viewWillAppear` has made the
        // window's style mask final (`.fullSizeContentView` decides how tall
        // the content view is) and pinned the content size — before that,
        // layouts run at transient sizes the child's early output would be
        // laid out against (D.1: a 28-row transient followed by the real 30
        // stranded two blank rows under the prompt). The session is
        // constructed at the target size already, so skipping early layouts
        // loses nothing.
        guard didSizeWindow, session != nil, let terminalRenderer, let window = view.window
        else { return }
        // The style-mask insertion lands one layout pass late: the first
        // layout after `setContentSize` still runs at the content-rect height
        // (frame minus titlebar — observed 522pt against the final 554pt),
        // and delivering that size shrinks the grid and strands content
        // exactly as above. With `.fullSizeContentView` effective the content
        // view spans the whole frame, so a view that does not fill its
        // window's frame is transient by construction; skip it.
        guard abs(view.bounds.height - window.frame.height) < 1 else { return }
        let usable = CGSize(
            width: view.bounds.width - TerminalLayout.insetWidth,
            height: view.bounds.height - TerminalLayout.insetHeight)
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
        let bottom = drawableSize.height - TerminalLayout.insets.bottom * scale
        return CGRect(
            x: TerminalLayout.insets.left * scale,
            y: max(TerminalLayout.insets.top * scale, bottom - gridHeight),
            width: max(0, drawableSize.width - TerminalLayout.insetWidth * scale),
            height: gridHeight)
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }
}
