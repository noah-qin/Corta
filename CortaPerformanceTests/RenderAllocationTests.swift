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
import Darwin
import Foundation
import Metal
import Synchronization
import Testing

/// Heap allocations made by the calling thread while `body` runs, counted
/// through libmalloc's `malloc_logger` hook (the same probe as the core's
/// `HotPathAllocationTests`, which a test target cannot share).
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private nonisolated(unsafe) var countedThread: pthread_t?
private let allocationCount = Atomic<Int>(0)
private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, let thread = countedThread, pthread_equal(thread, pthread_self()) != 0 else { return }
    allocationCount.add(1, ordering: .relaxed)
}
private func allocations(during body: () -> Void) -> Int {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1 }
    let slot = symbol.assumingMemoryBound(to: MallocLogger?.self)
    allocationCount.store(0, ordering: .relaxed)
    countedThread = pthread_self()
    let previous = slot.pointee
    slot.pointee = countingLogger
    body()
    slot.pointee = previous
    countedThread = nil
    return allocationCount.load(ordering: .relaxed)
}

extension PerformanceSuites {
    /// A frame's allocations are the encoder's and the command buffer's:
    /// a fixed count, whatever the damage. Glyphs, rules, block elements and
    /// clusters are built per cell without touching the heap.
    @Suite struct RenderAllocationTests {
        @Test func allocationsPerFrame() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
            let columns = 120, rows = 40
            let width = Int(renderer.metrics.cellWidth * CGFloat(columns))
            let height = Int(renderer.metrics.cellHeight * CGFloat(rows))
            let texture = try BenchmarkBuild.renderTarget(device: device, width: width, height: height)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let completed = DispatchSemaphore(value: 0)
            func frame(_ terminal: Terminal) -> Int {
                let count = allocations {
                    renderer.render(
                        grid: terminal.grid, scrollOffset: 0, rect: rect,
                        drawableSize: CGSize(width: width, height: height), cursorVisible: true,
                        selection: nil, target: texture, clearColor: MTLClearColorMake(0, 0, 0, 1)
                    ) { _ in completed.signal() }
                }
                completed.wait()
                return count
            }
            func fill(_ text: String) -> Terminal {
                var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 1000)
                for row in 0..<rows {
                    terminal.feed(Array("\u{1B}[\(31 + row % 7)m\(text)\u{1B}[0m".utf8))
                    if row < rows - 1 { terminal.feed(Array("\r\n".utf8)) }
                }
                return terminal
            }
            let asciiLine = String(repeating: "abcdefghij", count: 11) + "klmnopqr"
            let mixedLine = "中文 日本語 e\u{301} 👍🏽 👨‍👩‍👧 🇨🇳 ─┼─ █▓▒░ ascii text " + String(repeating: "x", count: 40)
            var results: [String: [Int]] = [:]
            for (name, line) in [("ascii", asciiLine), ("mixed", mixedLine)] {
                var terminal = fill(line)
                for _ in 0..<5 { renderer.invalidate(); _ = frame(terminal) }
                for _ in 0..<10 {
                    results["\(name) idle", default: []].append(frame(terminal))
                    renderer.invalidate()
                    results["\(name) full", default: []].append(frame(terminal))
                    terminal.feed(Array("y".utf8))
                    results["\(name) typing", default: []].append(frame(terminal))
                    terminal.feed(Array("\r\n".utf8) + Array(line.utf8))
                    results["\(name) scroll", default: []].append(frame(terminal))
                }
            }
            // The first frame of a scenario may rasterise a glyph or grow the
            // scroll journal; after it, damage must not change the count by
            // more than Metal's own bookkeeping, which drifts by a few from
            // frame to frame. One allocation per row would add 40 here, one
            // per cell thousands.
            let tolerance = 16
            for name in ["ascii", "mixed"] {
                let idle = results["\(name) idle"]!.dropFirst().max()!
                for kind in ["full", "typing", "scroll"] {
                    let steady = results["\(name) \(kind)"]!.dropFirst()
                    #expect(
                        steady.allSatisfy { $0 <= idle + tolerance },
                        "\(name) \(kind) allocates beyond its idle frame: \(Array(steady)) against \(idle)")
                }
            }
        }
    }
}
