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

import CortaTerminal
import Darwin
import Dispatch
import Foundation

// What history costs in memory, and where it goes.

func benchmarkScrollbackMemory() {
    let before = currentResidentBytes()
    let footprintBefore = currentFootprintBytes()
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 100_000)
    // 100k lines of realistic width so evicted rows aren't free of cost.
    let line = String(repeating: "x", count: 120) + "\r\n"
    let lineBytes = Array(line.utf8)
    for row in 0..<100_000 {
        terminal.feed(lineBytes)
        // Standalone Terminal has no reader queue. Model the session's idle
        // maintenance as batches seal, rather than deferring a whole history.
        if row.isMultiple(of: 256) { terminal.compressColdScrollback() }
    }
    terminal.compressColdScrollback()
    let footprintAfter = currentFootprintBytes()
    let after = currentResidentBytes()
    print("compressed history footprint delta: \(Int64(footprintAfter) - Int64(footprintBefore)) bytes")
    print(
        "memory @ 100k scrollback lines: \(String(format: "%.1f", Double(Int64(after) - Int64(before)) / 1_048_576)) MB "
            + "(resident before \(String(format: "%.1f", megabytes(before))) MB, after \(String(format: "%.1f", megabytes(after))) MB)"
    )
}

/// A profiler target: warm the history ring, then repeat the yes corpus
/// without retaining snapshots. The marker separates initial capacity growth
/// from steady-state recycling in an Allocations call tree.
func profileSteadyScrolling() {
    var terminal = Terminal(rows: 40, columns: 120, scrollbackLimit: 100_000)
    let bytes = Array([UInt8]("y\r\n".utf8).repeated(toCount: 1_048_576))
    terminal.feed(bytes)
    print("scroll allocations: STEADY begins (history warmed, no snapshotter)")
    fflush(stdout)
    let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
    var batches = 0
    while DispatchTime.now().uptimeNanoseconds < deadline {
        terminal.feed(bytes)
        batches += 1
    }
    print("scroll allocations: STEADY ends (\(batches) MiB batches)")
}

func diagnoseScrollbackFootprint() {
    var probe = ContiguousArray<Cell>()
    for _ in 0..<120 { probe.append(.blank) }
    let stride = MemoryLayout<Cell>.stride
    let usedBytes = 120 * stride
    let allocatedBytes = probe.capacity * stride
    print(
        "diagnostic: a 120-cell row grown one append at a time has capacity "
            + "\(probe.capacity) (stride \(stride)B) => \(allocatedBytes)B allocated vs "
            + "\(usedBytes)B used (\(allocatedBytes - usedBytes)B slack/row); "
            + "x100k rows => \((allocatedBytes - usedBytes) * 100_000 / 1_048_576)MB slack, "
            + "\(usedBytes * 100_000 / 1_048_576)MB actual cell data, "
            + "\(allocatedBytes * 100_000 / 1_048_576)MB allocated cell storage")
    print("diagnostic: sizeof(Line) = \(MemoryLayout<Line>.stride)B, x100k => \(MemoryLayout<Line>.stride * 100_000 / 1_048_576)MB for the outer array alone")
}
