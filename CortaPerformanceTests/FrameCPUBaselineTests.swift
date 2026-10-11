// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreText
import Corta
import CortaTerminal
import Foundation
import Metal
import Testing

extension PerformanceSuites {
    /// The frame-CPU baseline: frame CPU time, measured against a representative
    /// window (120×40, a typical terminal size) with the screen full of text —
    /// the worst case, which damage tracking would otherwise hide: every
    /// iteration calls `invalidate()` so the whole instance buffer is rebuilt,
    /// exactly what a full-screen scroll (vim paging, `cat` of a large file)
    /// costs. Not an assertion — `docs/PERFORMANCE.md`'s < 4 ms target is a
    /// design constraint to defend later, not a CI gate this early. The result
    /// is written to a file so it survives outside the ephemeral test log.
    ///
    /// This is D17's number, and it is a Release number: run it through
    /// `TestPlans/Release` (see `PerformanceSuites`). The report names the
    /// configuration it was built in.
    @Suite struct FrameCPUBaselineTests {
        /// The GPU-expansion gate is the existing 4 ms CPU budget, measured
        /// for four 400x120 panes. CPU-only timing ends before GPU waits.
        @Test func measureLargeGridGate() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            let renderers = try (0..<4).map { _ in try TerminalRenderer(device: device, font: font, scale: 1) }
            let columns = 400, rows = 120
            var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 0)
            for row in 0..<rows {
                terminal.feed(Array("\u{1B}[\(31 + row % 7)m\(String(repeating: "x", count: columns - 1))\r\n".utf8))
            }
            let width = Int(renderers[0].metrics.cellWidth * CGFloat(columns))
            let height = Int(renderers[0].metrics.cellHeight * CGFloat(rows))
            let targets = try renderers.map { _ in try BenchmarkBuild.renderTarget(device: device, width: width, height: height) }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let completed = DispatchSemaphore(value: 0)
            var report = "four 400x120 panes, CPU-only, gate 4 ms p50, \(BenchmarkBuild.configuration)\n"
            for full in [false, true] {
                var durations: [Double] = []
                for iteration in 0..<65 {
                    terminal.feed(Array("\u{1B}[1;1H\(iteration % 2 == 0 ? "y" : "z")".utf8))
                    if full { renderers.forEach { $0.invalidate() } }
                    let start = DispatchTime.now().uptimeNanoseconds
                    for (renderer, target) in zip(renderers, targets) {
                        renderer.render(grid: terminal.grid, rect: rect, drawableSize: rect.size,
                            cursorVisible: true, selection: nil, target: target,
                            clearColor: MTLClearColorMake(0, 0, 0, 1)) { _ in completed.signal() }
                    }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    for _ in renderers { completed.wait() }
                    if iteration >= 5 { durations.append(ms) }
                }
                durations.sort()
                report += "\(full ? "full rebuild" : "one row dirty"): p50 \(durations[30]) ms, p95 \(durations[57]) ms, p99 \(durations[59]) ms, max \(durations[59]) ms\n"
            }
            try report.write(toFile: "/tmp/corta-large-grid-gate.txt", atomically: true, encoding: .utf8)
        }

        @Test func measureFrameCPUTime() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                Issue.record("No Metal device available in this environment")
                return
            }
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

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
            let texture = try BenchmarkBuild.renderTarget(
                device: device, width: width, height: height)

            let iterations = 60
            var durations: [Double] = []
            let completed = DispatchSemaphore(value: 0)
            for _ in 0..<iterations {
                renderer.invalidate()  // force the full-rebuild worst case
                let start = DispatchTime.now()
                // The window runs to the frame's GPU completion, as it always has.
                renderer.render(
                    grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
                    drawableSize: CGSize(width: width, height: height), cursorVisible: true,
                    selection: nil, target: texture, clearColor: MTLClearColorMake(0, 0, 0, 1)
                ) { _ in completed.signal() }
                completed.wait()
                let elapsedMs =
                    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                durations.append(elapsedMs)
            }

            let average = durations.reduce(0, +) / Double(durations.count)
            let sorted = durations.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            let maximum = sorted.last!

            let report =
                "frame CPU time (\(columns)x\(rows), full screen, \(BenchmarkBuild.configuration)): avg \(String(format: "%.3f", average)) ms, p50 \(String(format: "%.3f", p50)) ms, p95 \(String(format: "%.3f", p95)) ms, p99 \(String(format: "%.3f", p99)) ms, max \(String(format: "%.3f", maximum)) ms, over \(iterations) iterations\n"
            let outputPath =
                ProcessInfo.processInfo.environment["CORTA_BASELINE_OUTPUT"]
                ?? "/tmp/corta-frame-cpu-baseline.txt"
            try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            #expect(average >= 0)  // always true; the measurement is the point
        }
    }
}
