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

    override func viewDidLoad() {
        super.viewDidLoad()

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }
        terminalRenderer = try! TerminalRenderer(device: device, font: font)
        commandQueue = device.makeCommandQueue()

        let view = TerminalView(frame: self.view.bounds)
        view.autoresizingMask = [.width, .height]
        self.view.addSubview(view)
        terminalView = view

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let initialColumns = UInt16(max(1, self.view.bounds.width / terminalRenderer.metrics.cellWidth))
        let initialRows = UInt16(max(1, self.view.bounds.height / terminalRenderer.metrics.cellHeight))
        session = try! TerminalSession(
            executable: shell, arguments: ["-l"],
            size: TerminalSize(rows: initialRows, columns: initialColumns))

        view.onRenderFrame = { [weak self] pass, drawableSize, drawable in
            self?.render(into: pass, drawableSize: drawableSize, drawable: drawable)
        }
        view.onKeyBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        view.onScroll = { [weak self] delta in
            self?.scroll(by: delta)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        resizeSessionToFitView()
    }

    private func resizeSessionToFitView() {
        guard let session, let terminalRenderer else { return }
        let columns = UInt16(max(1, view.bounds.width / terminalRenderer.metrics.cellWidth))
        let rows = UInt16(max(1, view.bounds.height / terminalRenderer.metrics.cellHeight))
        session.resize(to: TerminalSize(rows: rows, columns: columns))
    }

    private func scroll(by delta: Int) {
        let grid = session.snapshot()
        scrollOffset = min(max(0, scrollOffset + delta), grid.scrollback.count)
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
