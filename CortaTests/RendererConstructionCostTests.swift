import Foundation
import Metal
import Testing

@testable import Corta

/// B12 (issue #39): pane-creation cost driver. Every pane's
/// `TerminalRenderer` builds a `QuadRenderer`; before the per-device
/// pipeline cache, each of those compiled three `MTLRenderPipelineState`s
/// and re-serialised the `MTLBinaryArchive`, so splitting a window paid a
/// shader-compile-sized cost per new pane. This is the measurement harness
/// for that change — not an assertion (same convention as
/// `FrameCPUBaselineTests`): the per-construction distribution is written to
/// a file so it survives outside the ephemeral test log.
/// `.serialized` + `.metalSerialized`: shares the GPU with the other render
/// suites — see `SuiteSerialization.swift`.
@Suite(.serialized, .metalSerialized) struct RendererConstructionCostTests {
    @Test func measureRendererConstructionCost() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }

        // Construction #1 is forced cold (`resetForTesting`) so the report
        // shows the compile cost panes no longer pay past the first;
        // #2...#8 are the warm-cache cost every split pane actually hits.
        // Under XCTest the binary-archive read path is disabled
        // (`QuadRenderer.isRunningUnderXCTest`), so cold here means a real
        // compile — an upper bound on what a real launch's first pane pays.
        let constructions = 8
        var durations: [Double] = []
        QuadPipelineCache.resetForTesting()
        for _ in 0..<constructions {
            let start = DispatchTime.now()
            _ = try QuadRenderer(device: device)
            let elapsedMs =
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            durations.append(elapsedMs)
        }

        let sorted = durations.sorted()
        let count = sorted.count
        let p50 = sorted[count / 2]
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
        let max = sorted[count - 1]
        let perConstruction = durations.enumerated()
            .map { "  #\($0.offset + 1): \(String(format: "%.3f", $0.element)) ms" }
            .joined(separator: "\n")
        let report = """
            renderer construction cost (\(constructions) QuadRenderer inits, one device):
            \(perConstruction)
            p50 \(String(format: "%.3f", p50)) ms, p95 \(String(format: "%.3f", p95)) ms, max \(String(format: "%.3f", max)) ms

            """
        let outputPath =
            ProcessInfo.processInfo.environment["CORTA_CONSTRUCTION_OUTPUT"]
            ?? "/tmp/corta-renderer-construction.txt"
        try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
        #expect(p50 >= 0)  // always true; the measurement is the point
    }
}
