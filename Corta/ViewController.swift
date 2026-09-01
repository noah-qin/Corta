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

/// Owns one `TerminalSession` and the `TerminalRenderer`/`TerminalView` that
/// draw it — the unit a split (M5) will multiply, not a global (`DESIGN.md`
/// §2.4).
class ViewController: NSViewController {
    private var terminalView: TerminalView!
    private var terminalRenderer: TerminalRenderer!
    private var session: TerminalSession!
    private var commandQueue: MTLCommandQueue!
    private var scrollOffset = 0
    private var didSizeWindow = false
    /// Set by layout changes the damage diff cannot see (drawable size,
    /// backing scale); consumed by `updateDamage`.
    private var needsRedraw = true

    /// Initial and minimum grid sizes. The window's content size is derived
    /// from these and the font's cell metrics, never from hardcoded points,
    /// so it follows a font or size change.
    private let defaultColumns = 80
    private let defaultRows = 24
    private let minimumColumns = 20
    private let minimumRows = 5

    override func viewDidLoad() {
        super.viewDidLoad()

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }
        terminalRenderer = try! TerminalRenderer(device: device, font: font)
        commandQueue = device.makeCommandQueue()

        let metrics = terminalRenderer.metrics
        let contentSize = NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight)
        let view = TerminalView(frame: NSRect(origin: .zero, size: contentSize))
        view.autoresizingMask = [.width, .height]
        self.view.addSubview(view)
        terminalView = view

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        session = try! TerminalSession(
            executable: shell, arguments: ["-l"],
            size: TerminalSize(rows: UInt16(defaultRows), columns: UInt16(defaultColumns)))

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSizeWindow, let window = view.window else { return }
        didSizeWindow = true
        let metrics = terminalRenderer.metrics
        // Dragging snaps to whole cells, so a resize never leaves a partial
        // row or column.
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight)
        window.setContentSize(NSSize(
            width: CGFloat(defaultColumns) * metrics.cellWidth,
            height: CGFloat(defaultRows) * metrics.cellHeight))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Layout can change the drawable's size or backing scale without any
        // grid change the damage diff would notice — force one frame.
        needsRedraw = true
        resizeSessionToFitView()
    }

    /// Runs at vsync before a drawable is acquired: diffs the latest snapshot
    /// against the renderer's line-granular cache so a static screen costs no
    /// frame at all (`PERFORMANCE.md` §3).
    private func updateDamage() -> Bool {
        let grid = session.snapshot()
        let damaged = terminalRenderer.updateInstances(
            grid: grid, scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0, selection: nil)
        if needsRedraw {
            needsRedraw = false
            return true
        }
        return damaged
    }

    private func resizeSessionToFitView() {
        guard let session, let terminalRenderer else { return }
        let columns = UInt16(max(1, view.bounds.width / terminalRenderer.metrics.cellWidth))
        let rows = UInt16(max(1, view.bounds.height / terminalRenderer.metrics.cellHeight))
        session.resize(to: TerminalSize(rows: rows, columns: columns))
    }

    private func scroll(_ gesture: ScrollGesture) {
        let historyDepth = session.snapshot().scrollback.count
        switch gesture {
        case .lines(let delta):
            scrollOffset = min(max(0, scrollOffset + delta), historyDepth)
        case .page(let up):
            let rows = Int(view.bounds.height / terminalRenderer.metrics.cellHeight)
            scrollOffset = min(max(0, scrollOffset + (up ? rows : -rows)), historyDepth)
        case .toTop:
            scrollOffset = historyDepth
        case .toBottom:
            scrollOffset = 0
        }
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
            rect: CGRect(origin: .zero, size: drawableSize), drawableSize: drawableSize,
            cursorVisible: scrollOffset == 0, selection: nil,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }
}
