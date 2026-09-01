import CoreGraphics
import CoreText
import CortaTerminal
import Foundation
import Metal
import Testing

@testable import Corta

/// M1.21's baseline: frame CPU time, measured against a representative
/// window (120×40, a typical terminal size) with the screen full of text —
/// the worst case, which damage tracking would otherwise hide: every
/// iteration calls `invalidate()` so the whole instance buffer is rebuilt,
/// exactly what a full-screen scroll (vim paging, `cat` of a large file)
/// costs. Not an assertion — `docs/PERFORMANCE.md`'s < 4 ms target is a
/// design constraint to defend later, not a CI gate this early. The result
/// is written to a file so it survives outside the ephemeral test log.
struct FrameCPUBaselineTests {
    @Test func measureFrameCPUTime() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font)

        let columns = 120, rows = 40
        var terminal = Terminal(rows: rows, columns: columns)
        // Fill the screen with SGR-varied text — the worst case for instance
        // buffer construction, not the best case of a mostly-blank screen.
        for row in 0..<rows {
            let colorCode = 31 + (row % 7)
            terminal.feed(
                Array(
                    "\u{1B}[\(colorCode)m\(String(repeating: "x", count: columns - 1))\u{1B}[0m\r\n"
                        .utf8))
        }
        let grid = terminal.grid

        let width = Int(renderer.metrics.cellWidth * CGFloat(columns))
        let height = Int(renderer.metrics.cellHeight * CGFloat(rows))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = device.makeTexture(descriptor: descriptor)!

        let iterations = 60
        var durations: [Double] = []
        for _ in 0..<iterations {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store

            let commandBuffer = queue.makeCommandBuffer()!
            renderer.invalidate()  // force the full-rebuild worst case
            let start = DispatchTime.now()
            renderer.render(
                grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
                drawableSize: CGSize(width: width, height: height), cursorVisible: true,
                selection: nil, renderPassDescriptor: pass, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let elapsedMs =
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            durations.append(elapsedMs)
        }

        let average = durations.reduce(0, +) / Double(durations.count)
        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]

        let report =
            "frame CPU time (\(columns)x\(rows), full screen): avg \(String(format: "%.3f", average)) ms, p95 \(String(format: "%.3f", p95)) ms, over \(iterations) iterations\n"
        let outputPath =
            ProcessInfo.processInfo.environment["CORTA_BASELINE_OUTPUT"]
            ?? "/tmp/corta-frame-cpu-baseline.txt"
        try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
        #expect(average >= 0)  // always true; the measurement is the point
    }
}
