import CoreGraphics
import CoreText
import CortaTerminal
import Foundation
import Metal
import Testing

@testable import Corta

/// B12 (issue #39) bounded-partial-upload experiment harness: frame CPU
/// time for the three damage shapes a terminal actually produces, at a
/// representative 120×40 screen full of SGR-varied text (same fixture as
/// `FrameCPUBaselineTests`):
///
/// - **typing** — one cell appended at the cursor: one damaged row, plus
///   the cursor-overlay rebuild;
/// - **scroll** — one newline past the bottom margin: `applyScrollShift`
///   moves every surviving instance's Y and one row rebuilds;
/// - **full rebuild** — `invalidate()`, the vim-paging worst case.
///
/// Not an assertion — the distributions are written to a file, the same
/// convention as `FrameCPUBaselineTests`. The experiment it was built for
/// (uploading only damaged instance ranges rather than every array in
/// full) was measured with it and not kept: typing gained ~15 µs p50
/// against a 4 ms frame budget while scroll and full-rebuild — the cases
/// where upload volume is real — cannot win by construction, and paid the
/// bookkeeping. The numbers are in the commit that introduced this file;
/// the harness stays for any future upload-path change, matching the
/// prewarm precedent in `docs/PERFORMANCE.md`.
/// `.serialized` + `.metalSerialized`: builds a `GlyphAtlas` — see
/// `SuiteSerialization.swift`.
@Suite(.serialized, .metalSerialized) struct InstanceUploadBenchmarkTests {
    @Test func measureUploadScenarios() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        let columns = 120, rows = 40
        let width = Int(renderer.metrics.cellWidth * CGFloat(columns))
        let height = Int(renderer.metrics.cellHeight * CGFloat(rows))
        let texture = MetalRenderTarget.make(device: device, width: width, height: height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let drawableSize = CGSize(width: width, height: height)

        /// A screen full of SGR-varied text — the same fill
        /// `FrameCPUBaselineTests` measures against.
        func makeTerminal() -> Terminal {
            var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 1000)
            for row in 0..<rows {
                let colorCode = 31 + (row % 7)
                terminal.feed(
                    Array(
                        "\u{1B}[\(colorCode)m\(String(repeating: "x", count: columns - 1))\u{1B}[0m\r\n"
                            .utf8))
            }
            return terminal
        }

        /// One measured frame: the CPU-side `render` call (diff, rebuild,
        /// upload, encode) is the window; the commit is outside it. The GPU
        /// is paced every eighth frame so the queue stays bounded without a
        /// per-frame wait landing inside the measured window.
        var lastCommandBuffer: MTLCommandBuffer?
        func drawFrame(grid: Grid) -> Double {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            let commandBuffer = queue.makeCommandBuffer()!
            let start = DispatchTime.now()
            renderer.render(
                grid: grid, rect: rect, drawableSize: drawableSize, cursorVisible: true,
                selection: nil, renderPassDescriptor: pass, commandBuffer: commandBuffer)
            let elapsedMs =
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            commandBuffer.commit()
            lastCommandBuffer = commandBuffer
            return elapsedMs
        }

        let iterations = 60
        func runScenario(_ mutate: (inout Terminal) -> Void) -> [Double] {
            var terminal = makeTerminal()
            // Warm-up: rasterises the scenario's glyphs into the atlas and
            // settles the damage cache, so iteration 1 is not a cold outlier
            // in every percentile.
            for _ in 0..<5 {
                mutate(&terminal)
                _ = drawFrame(grid: terminal.grid)
            }
            lastCommandBuffer?.waitUntilCompleted()
            var durations: [Double] = []
            for iteration in 0..<iterations {
                mutate(&terminal)
                durations.append(drawFrame(grid: terminal.grid))
                if iteration % 8 == 7 { lastCommandBuffer?.waitUntilCompleted() }
            }
            lastCommandBuffer?.waitUntilCompleted()
            return durations
        }

        var typed = false
        let typing = runScenario { terminal in
            // Alternate so the write is never a same-scalar no-op.
            terminal.feed(Array((typed ? "z" : "y").utf8))
            typed.toggle()
        }
        let scroll = runScenario { terminal in
            terminal.feed(Array("\r\n".utf8))
        }
        let fullRebuild = runScenario { _ in
            renderer.invalidate()
        }

        func summarise(_ name: String, _ durations: [Double]) -> String {
            let sorted = durations.sorted()
            let count = sorted.count
            let p50 = sorted[count / 2]
            let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
            let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))]
            let max = sorted[count - 1]
            return String(
                format: "%@: p50 %.3f ms, p95 %.3f ms, p99 %.3f ms, max %.3f ms (n=%d)",
                name, p50, p95, p99, max, count)
        }

        let report = """
            instance upload benchmark (\(columns)x\(rows), full text screen, Menlo 14 @1x)
            \(summarise("typing (1 row dirty)      ", typing))
            \(summarise("scroll (shift + 1 row)    ", scroll))
            \(summarise("full rebuild              ", fullRebuild))

            """
        let outputPath =
            ProcessInfo.processInfo.environment["CORTA_UPLOAD_OUTPUT"]
            ?? "/tmp/corta-instance-upload.txt"
        try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
        #expect(!typing.isEmpty)  // always true; the measurement is the point
    }
}
