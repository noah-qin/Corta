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

// Reflow and search over a full scrollback.

/// `ResizeDebouncer` is trailing-only: a drag in continuous motion delivers
/// nothing until the stream pauses for 100ms or ends, so "stays smooth"
/// means one reflow after the gesture, not one inside a frame budget. The
/// throttle alternative is measured head-to-head in
/// `benchmarkResizeStrategies` below.
func benchmarkReflowCost() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = String(repeating: "the quick brown fox jumps over ", count: 4) + "\r\n"  // wraps at 120
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    if CommandLine.arguments.contains("--compressed") { terminal.compressColdScrollback() }
    let start = DispatchTime.now()
    var grid = terminal.grid
    grid.resize(rows: 50, columns: 80)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    print(
        "reflow cost, 100k-line scrollback, 120 -> 80 columns: \(String(format: "%.1f", elapsedMs)) ms "
            + "(one resize call; ResizeDebouncer coalesces a live drag to ~1 call/100ms)")
}

func benchmarkSearchCost() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    let before = currentResidentBytes()
    let start = DispatchTime.now()
    let matches = Search.find("fox", in: terminal.grid)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    let after = currentResidentBytes()
    print(
        "search cost, 100k-line scrollback, one query: \(String(format: "%.1f", elapsedMs)) ms, "
            + "\(matches.count) matches, resident delta \(String(format: "%.1f", megabytes(after - before))) MB "
            + "(should not be anywhere near a full-scrollback copy)")
}

/// The single-shot `benchmarkSearchCost` above answers "how expensive is one
/// query"; P11 wants the distribution a user actually hits — the cold first
/// query (allocator and caches cold, which is what the first keystroke of a
/// search feels) reported separately from the warmed steady state.
func benchmarkSearchResponseDistribution() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    let coldStart = DispatchTime.now()
    _ = Search.find("fox", in: terminal.grid)
    let coldMs = Double(DispatchTime.now().uptimeNanoseconds - coldStart.uptimeNanoseconds) / 1e6

    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(50)
    for _ in 0..<50 {
        let start = DispatchTime.now()
        _ = Search.find("fox", in: terminal.grid)
        samplesNanoseconds.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
    }
    guard let warmed = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else { return }
    print(
        "search response, 100k-line scrollback: cold \(String(format: "%.1f", coldMs)) ms, "
            + "then warmed \(warmed.description)")
}

/// The case the ASCII fast path (#115) cannot take, and the one it could
/// make *worse*: an ASCII query over a document whose lines are not ASCII,
/// so `fillWithASCIILogicalLine` is attempted and rejected on every line
/// before the `String` path runs anyway. If this number moves up, the fast
/// path is being paid for by the searches that cannot use it.
///
/// The non-ASCII character sits at the *end* of the line deliberately. Put
/// it near the front and the byte walk bails after a few cells, which is
/// the cheap case and measures almost nothing; a log line terminated by a
/// status glyph — `✓`, `…`, a box-drawing character — makes the walk
/// traverse the whole chain before rejecting it, so the row is walked
/// twice. That is the shape this guard has to be able to see.
func benchmarkNonASCIISearchResponse() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog ✓\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(50)
    for _ in 0..<50 {
        let start = DispatchTime.now()
        _ = Search.find("fox", in: terminal.grid)
        samplesNanoseconds.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
    }
    guard let warmed = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else { return }
    print(
        "search response, 100k-line non-ASCII scrollback, ASCII query: "
            + warmed.description)
}

/// `--cold-history`: a 100k-line history compressed, then searched and
/// reflowed, with memory at each step.
@inline(never) func makeColdHistory() -> Grid {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    for row in 0..<100_050 {
        terminal.feed(Array(("log \(row) " + String(repeating: "abcdef0123456789", count: 6) + " needle\r\n").utf8))
        if !CommandLine.arguments.contains("--deferred"), row.isMultiple(of: 256) { terminal.compressColdScrollback() }
    }
    return terminal.grid
}

func probeColdHistory() {
    var grid = makeColdHistory()
    print("history before drain cells \(grid.scrollback.storedCellBytes) RSS \(currentResidentBytes()) footprint \(currentFootprintBytes())")
    let start = DispatchTime.now().uptimeNanoseconds
    grid.scrollback.compressColdBatches()
    var mallocStats = malloc_statistics_t()
    malloc_zone_statistics(nil, &mallocStats)
    print("malloc in use \(mallocStats.size_in_use) allocated \(mallocStats.size_allocated)")
    print("history compressed cells \(grid.scrollback.storedCellBytes) capacity \(grid.scrollback.retainedCellCapacityBytes) RSS \(currentResidentBytes()) footprint \(currentFootprintBytes()) batches \(grid.scrollback.compressedBatchCount) encode ms \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)")
    for query in ["absent", "needle", "log 90000"] {
        for run in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let matches = Search.find(query, in: grid)
            print("history search \(query) run \(run): \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms count \(matches.count) RSS \(currentResidentBytes())")
        }
    }
    let reflow = DispatchTime.now().uptimeNanoseconds
    grid.resize(rows: 50, columns: 80)
    print("history reflow ms \(Double(DispatchTime.now().uptimeNanoseconds - reflow) / 1e6) RSS \(currentResidentBytes())")
}

/// `--search-only`: search over 100k plain lines, optionally compressed.
func probeSearchOnly() {
    var grid = { () -> Grid in
        var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
        for _ in 0..<100_000 { terminal.feed(Array("the quick brown fox jumps over the lazy dog\r\n".utf8)) }
        return terminal.grid
    }()
    if CommandLine.arguments.contains("--compressed") { grid.scrollback.compressColdBatches() }
    for _ in 0..<5 {
        let start = DispatchTime.now().uptimeNanoseconds
        let matches = Search.find("fox", in: grid)
        print("search-only \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms \(matches.count)")
    }
}

