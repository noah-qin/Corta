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
            let bench = try UploadBench(device: device)
            let rows = UploadBench.rows

            var typed = false
            let typing = bench.runScenario("typing") { terminal in
                // Alternate so the write is never a same-scalar no-op.
                terminal.feed(Array((typed ? "z" : "y").utf8))
                typed.toggle()
            }
            let scroll = bench.runScenario("scroll") { terminal in
                terminal.feed(Array("\r\n".utf8))
            }
            let fullRebuild = bench.runScenario("full rebuild") { _ in
                bench.renderer.invalidate()
            }
            var redraws = 0
            let redraw = bench.runScenario("redraw") { terminal in
                redraws += 1
                UploadBench.redrawEveryRow(&terminal, pass: redraws)
            }
            let blockRebuild = bench.runScenario("blocks") { terminal in
                UploadBench.fillWithBlocks(&terminal)
                bench.renderer.invalidate()
            }
            let regionScroll = bench.runScenario("region scroll", UploadBench.scrollRegionByOne)
            let historyOne = bench.historyScenario("history scroll by 1", step: 1, flood: false)
            let historyThird = bench.historyScenario("history scroll by third", step: rows / 3, flood: false)
            let anchoredFlood = bench.historyScenario("flood while scrolled back", step: 0, flood: true)

            let report = bench.report([
                ("typing (1 row dirty)      ", typing),
                ("scroll (shift + 1 row)    ", scroll),
                ("full rebuild              ", fullRebuild),
                ("every row redrawn         ", redraw),
                ("full rebuild, blocks      ", blockRebuild),
                ("region scroll by 1        ", regionScroll),
                ("history scroll by 1       ", historyOne),
                ("history scroll by third   ", historyThird),
                ("flood while scrolled back ", anchoredFlood),
            ])
            let outputPath =
                ProcessInfo.processInfo.environment["CORTA_UPLOAD_OUTPUT"]
                ?? "/tmp/corta-instance-upload.txt"
            try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            #expect(!typing.isEmpty)  // always true; the measurement is the point
        }
    }

    /// The renderer, its target and the per-scenario upload tallies the
    /// upload benchmark measures with.
    final class UploadBench {
        static let columns = 120
        static let rows = 40
        static let iterations = 60
        let renderer: TerminalRenderer
        private let texture: MTLTexture
        private let rect: CGRect
        private let completed = DispatchSemaphore(value: 0)
        private var uploadBytes: [String: [Int]] = [:]
        private var scenarioName = ""

        init(device: MTLDevice) throws {
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            renderer = try TerminalRenderer(device: device, font: font, scale: 1)
            let width = Int(renderer.metrics.cellWidth * CGFloat(Self.columns))
            let height = Int(renderer.metrics.cellHeight * CGFloat(Self.rows))
            texture = try BenchmarkBuild.renderTarget(device: device, width: width, height: height)
            rect = CGRect(x: 0, y: 0, width: width, height: height)
        }

        /// A screen full of SGR-varied text — the same fill
        /// `FrameCPUBaselineTests` measures against.
        static func makeTerminal() -> Terminal {
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

        /// Every row erased and rewritten at a length that changes per pass,
        /// as a full-screen program repaints.
        static func redrawEveryRow(_ terminal: inout Terminal, pass: Int) {
            var bytes = Array("\u{1B}[H".utf8)
            for row in 0..<rows {
                let length = columns / 2 + (row * 7 + pass * 13) % (columns / 2)
                bytes += Array("\u{1B}[2K\u{1B}[\(31 + row % 7)m".utf8)
                bytes += Array(repeating: UInt8(ascii: "x"), count: length)
                if row < rows - 1 { bytes += Array("\r\n".utf8) }
            }
            terminal.feed(bytes)
        }

        /// A new line at the bottom of a scroll region one row short of the
        /// screen.
        static func scrollRegionByOne(_ terminal: inout Terminal) {
            terminal.feed(
                Array(
                    "\u{1B}[1;39r\u{1B}[39;1H\r\n\u{1B}[32m\(String(repeating: "x", count: columns - 1))\u{1B}[0m"
                        .utf8))
        }

        /// Progress bars and shades over the whole screen, written once.
        static func fillWithBlocks(_ terminal: inout Terminal) {
            let blocks = Array("█▓▒░▀▄▌▐▖▗▘▙▚▛▜▝▞▟▁▂▃▄▅▆▇".unicodeScalars)
            guard terminal.grid.line(0)[0].scalar != blocks[0].value else { return }
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

        /// One measured frame: the CPU-side `render` call (diff, rebuild,
        /// upload, encode, commit) is the window. Each frame's GPU
        /// completion is waited for *after* the window closes: a frame
        /// slot is free only once its previous frame completed
        /// (`Metal4Backend`), so without the wait the fourth frame would
        /// time the GPU instead of the CPU.
        func drawFrame(grid: Grid, offset: Int = 0) -> Double {
            let completed = completed
            let start = DispatchTime.now()
            renderer.render(
                grid: grid, scrollOffset: offset, cursorVisible: true, selection: nil,
                into: FrameTarget(
                    texture: texture, rect: rect, drawableSize: rect.size,
                    clearColor: MTLClearColorMake(0, 0, 0, 1))) { _ in completed.signal() }
            let elapsedMs =
                Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            uploadBytes[scenarioName, default: []].append(
                renderer.uploadedInstanceBytes + renderer.uploadedRectangleBytes)
            completed.wait()
            return elapsedMs
        }

        func runScenario(_ name: String, _ mutate: (inout Terminal) -> Void) -> [Double] {
            scenarioName = name
            var terminal = Self.makeTerminal()
            // Warm-up: rasterises the scenario's glyphs into the atlas and
            // settles the damage cache, so iteration 1 is not a cold outlier
            // in every percentile.
            for _ in 0..<5 {
                mutate(&terminal)
                _ = drawFrame(grid: terminal.grid)
            }
            var durations: [Double] = []
            for _ in 0..<Self.iterations {
                mutate(&terminal)
                durations.append(drawFrame(grid: terminal.grid))
            }
            return durations
        }

        func historyScenario(_ name: String, step: Int, flood: Bool) -> [Double] {
            scenarioName = name
            var terminal = Self.makeTerminal()
            for i in 0..<8000 {
                terminal.feed(
                    Array(
                        "\u{1B}[\(31 + i % 7)m\(String(repeating: "x", count: Self.columns - 1))\u{1B}[0m\r\n"
                            .utf8))
            }
            terminal.compressColdScrollback()
            var offset = 4000
            _ = drawFrame(grid: terminal.grid, offset: offset)
            var values: [Double] = []
            for i in 0..<(Self.iterations + 5) {
                if flood {
                    let before = terminal.grid.scrollback.totalPushed
                    terminal.feed(Array("\r\nflood".utf8))
                    offset += terminal.grid.scrollback.totalPushed - before
                } else {
                    offset += i.isMultiple(of: 2) ? step : -step
                }
                let duration = drawFrame(grid: terminal.grid, offset: offset)
                if i >= 5 { values.append(duration) }
            }
            return values
        }

        /// The upload tallies, then one distribution line per scenario.
        func report(_ results: [(label: String, durations: [Double])]) -> String {
            let header = """
                instance stride: \(renderer.instanceStride) bytes; uploads include rectangle table
                \(uploadSummary)
                instance upload benchmark (\(Self.columns)x\(Self.rows), full text screen, Menlo 14 @1x, \
                \(BenchmarkBuild.configuration))
                """
            return ([header] + results.map { Self.summarise($0.label, $0.durations) }).joined(separator: "\n") + "\n"
        }

        /// Median bytes uploaded per frame, per scenario.
        var uploadSummary: String {
            uploadBytes.keys.sorted().map { name in
                let bytes = uploadBytes[name]!.sorted()
                return "\(name): \(bytes[bytes.count / 2]) bytes/frame p50"
            }.joined(separator: "\n")
        }

        static func summarise(_ name: String, _ durations: [Double]) -> String {
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
    }
}
