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
    /// Bounded-partial-upload experiment harness: frame CPU
    /// time for the three damage shapes a terminal actually produces, at a
    /// representative 120×40 screen full of SGR-varied text (same fixture as
    /// `FrameCPUBaselineTests`):
    ///
    /// - **typing** — one cell appended at the cursor: one damaged row, plus
    ///   the cursor-overlay rebuild;
    /// - **scroll** — one newline past the bottom margin: `applyScrollShift`
    ///   moves every surviving instance's Y and one row rebuilds;
    /// - **full rebuild** — `invalidate()`, the vim-paging worst case.
    /// - **every row redrawn** — the whole screen rewritten in place with
    ///   rows of a different length each frame, the shape of a TUI redrawing
    ///   or a flood without a scroll: every row is damaged and changes its
    ///   instance count, the case per-row splicing pays most for.
    /// - **full rebuild, block elements** — `invalidate()` over a screen of
    ///   progress bars and shades (U+2580–U+259F), drawn as geometry.
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
    @Suite struct InstanceUploadBenchmarkTests {
        @Test func measureUploadScenarios() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                Issue.record("No Metal device available in this environment")
                return
            }
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

            let columns = 120, rows = 40
            let width = Int(renderer.metrics.cellWidth * CGFloat(columns))
            let height = Int(renderer.metrics.cellHeight * CGFloat(rows))
            let texture = try BenchmarkBuild.renderTarget(device: device, width: width, height: height)
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
            /// upload, encode, commit) is the window. Each frame's GPU
            /// completion is waited for *after* the window closes: a frame
            /// slot is free only once its previous frame completed
            /// (`Metal4Backend`), so without the wait the fourth frame would
            /// time the GPU instead of the CPU.
            let completed = DispatchSemaphore(value: 0)
            func drawFrame(grid: Grid) -> Double {
                let start = DispatchTime.now()
                renderer.render(
                    grid: grid, rect: rect, drawableSize: drawableSize, cursorVisible: true,
                    selection: nil, target: texture, clearColor: MTLClearColorMake(0, 0, 0, 1)
                ) { _ in completed.signal() }
                let elapsedMs =
                    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                completed.wait()
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
                var durations: [Double] = []
                for _ in 0..<iterations {
                    mutate(&terminal)
                    durations.append(drawFrame(grid: terminal.grid))
                }
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
            var redraws = 0
            let redraw = runScenario { terminal in
                redraws += 1
                var bytes = Array("\u{1B}[H".utf8)
                for row in 0..<rows {
                    let length = columns / 2 + (row * 7 + redraws * 13) % (columns / 2)
                    bytes += Array("\u{1B}[2K\u{1B}[\(31 + row % 7)m".utf8)
                    bytes += Array(repeating: UInt8(ascii: "x"), count: length)
                    if row < rows - 1 { bytes += Array("\r\n".utf8) }
                }
                terminal.feed(bytes)
            }

            let blocks = Array("█▓▒░▀▄▌▐▖▗▘▙▚▛▜▝▞▟▁▂▃▄▅▆▇".unicodeScalars)
            let blockRebuild = runScenario { terminal in
                if terminal.grid.line(0)[0].scalar != blocks[0].value {
                    var bytes = Array("\u{1B}[H".utf8)
                    for row in 0..<rows {
                        var text = ""
                        for column in 0..<(columns - 1) {
                            text.unicodeScalars.append(blocks[(row + column) % blocks.count])
                        }
                        bytes += Array("\u{1B}[\(31 + row % 7)m\(text)".utf8)
                        if row < rows - 1 { bytes += Array("\r\n".utf8) }
                    }
                    terminal.feed(bytes)
                }
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
                instance upload benchmark (\(columns)x\(rows), full text screen, Menlo 14 @1x, \(BenchmarkBuild.configuration))
                \(summarise("typing (1 row dirty)      ", typing))
                \(summarise("scroll (shift + 1 row)    ", scroll))
                \(summarise("full rebuild              ", fullRebuild))
                \(summarise("every row redrawn         ", redraw))
                \(summarise("full rebuild, blocks      ", blockRebuild))

                """
            let outputPath =
                ProcessInfo.processInfo.environment["CORTA_UPLOAD_OUTPUT"]
                ?? "/tmp/corta-instance-upload.txt"
            try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            #expect(!typing.isEmpty)  // always true; the measurement is the point
        }
    }
}
