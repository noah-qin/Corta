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
        "memory @ 100k scrollback lines: "
            + "\(String(format: "%.1f", Double(Int64(after) - Int64(before)) / 1_048_576)) MB "
            + "(resident before \(String(format: "%.1f", megabytes(before))) "
            + "MB, after \(String(format: "%.1f", megabytes(after))) MB)"
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

/// What a 100,000-line history holds against what it has reserved, for plain
/// text and for a dense 256-colour SGR line, before and after the cold batches
/// are compressed. The numbers come from the real `Scrollback` (its batched
/// arenas and the compressed buffers), not from a bare array grown one append
/// at a time, which never was how a row reaches history (#537).
func diagnoseScrollbackFootprint() {
    let corpora: [(String, String)] = [
        ("ASCII, 120 columns", String(repeating: "x", count: 119)),
        ("ASCII, 72 columns", String(repeating: "abcdefg ", count: 9)),
        ("256-colour SGR on every line", String(repeating: "\u{1B}[38;5;196mab\u{1B}[0m", count: 30)),
    ]
    for (name, text) in corpora {
        var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
        let bytes = Array((text + "\r\n").utf8)
        for _ in 0..<100_000 { terminal.feed(bytes) }
        func line(_ stage: String, _ scrollback: Scrollback) {
            let stored = scrollback.storedCellBytes, reserved = scrollback.retainedCellCapacityBytes
            print(
                "diagnostic: \(name), \(stage): \(stored / 1024) KiB held, \(reserved / 1024) KiB reserved "
                    + "(\(String(format: "%.1f", 100 * Double(reserved - stored) / Double(max(1, stored)))) % slack), "
                    + "\(scrollback.compressedBatchCount) compressed batches")
        }
        line("before compressing", terminal.grid.scrollback)
        terminal.grid.scrollback.compressColdBatches()
        line("after compressing", terminal.grid.scrollback)
    }
    print(
        "diagnostic: sizeof(Line) = \(MemoryLayout<Line>.stride)B, x100k => "
            + "\(MemoryLayout<Line>.stride * 100_000 / 1_048_576)MB for the outer array alone"
    )
}

/// `--flood-memory` (#526): the core's share of a pane's memory after the
/// three floods the issue names, each twice, with history compressed as the
/// session's idle maintenance does it. Input is generated a megabyte at a time,
/// so no corpus sits in memory beside the terminal. Every step prints the
/// process footprint and resident size, malloc's in-use and allocated bytes (the
/// difference is what the allocator holds free), and what the history holds and
/// has reserved. The app adds the glyph atlas, GPU buffers and the window on top;
/// that part is read from `footprint` and `vmmap` on the running application.
func benchmarkFloodMemory() {
    /// Each call returns about a megabyte of lines; `chunk` numbers them.
    let floods: [(name: String, megabytes: Int, make: (Int) -> [UInt8])] = [
        ("64 MiB ASCII log", 64, { _ in
            var bytes: [UInt8] = []
            for index in 0..<8_900 {
                bytes += Array(
                    "2026-11-12T08:\(10 + index % 8):01Z INFO request \(index % 8 * 7919) served in \(index % 8 + 3) ms path=/api/v1/items/\(index % 8 * 31) status=200\r\n"
                        .utf8)
            }
            return bytes
        }),
        ("64 MiB CJK log", 64, { _ in
            var bytes: [UInt8] = []
            let line = Array("终端性能测试日志:状态正常，请求已处理，耗时三毫秒，路径 /接口/列表/项目 结果成功。日本語の文章も含まれます\r\n".utf8)
            for _ in 0..<9_500 { bytes += line }
            return bytes
        }),
        ("29 MiB dense SGR, 400,000 lines", 29, { chunk in
            var bytes: [UInt8] = []
            for offset in 0..<13_800 {
                let index = chunk * 13_800 + offset
                bytes += Array(
                    "\u{1B}[1;4;38;5;\(index % 256)mbold\u{1B}[0m \u{1B}[38;2;\(index % 256);\((index / 3) % 256);128mtruecolour\u{1B}[0m \u{1B}[48;5;\((index / 7) % 256)mfill\u{1B}[0m line \(index)\r\n"
                        .utf8)
            }
            return bytes
        }),
    ]
    // Compress after every this many 16 KiB reads: the session does it as each
    // batch of rows seals, so the default is a read in four, not a megabyte.
    // The allocator keeps what a burst of uncompressed history frees, so the
    // footprint depends on it (`--compress-every 64` shows how much).
    var compressEvery = 4
    if let flag = CommandLine.arguments.firstIndex(of: "--compress-every"),
        flag + 1 < CommandLine.arguments.count, let value = Int(CommandLine.arguments[flag + 1]), value > 0
    {
        compressEvery = value
    }
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let baselineFootprint = currentFootprintBytes()
    let baselineResident = currentResidentBytes()
    func report(_ step: String) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let scrollback = terminal.grid.scrollback
        print(
            "flood \(step): footprint +\(String(format: "%.1f", megabytes(currentFootprintBytes() &- baselineFootprint))) MB, "
                + "resident +\(String(format: "%.1f", megabytes(currentResidentBytes() &- baselineResident))) MB, "
                + "malloc in use \(String(format: "%.1f", Double(stats.size_in_use) / 1_048_576)) MB of "
                + "\(String(format: "%.1f", Double(stats.size_allocated) / 1_048_576)) MB allocated, "
                + "history holds \(String(format: "%.1f", Double(scrollback.storedCellBytes) / 1_048_576)) MB "
                + "reserves \(String(format: "%.1f", Double(scrollback.retainedCellCapacityBytes) / 1_048_576)) MB")
    }
    report("start, empty")
    for flood in floods {
        for pass in 1...2 {
            for chunk in 0..<(flood.megabytes) {
                if CommandLine.arguments.contains("--trace"), pass == 1, chunk < 20 { report("  \(flood.name) MiB \(chunk)") }
                let bytes = flood.make(flood.name.hasPrefix("29") ? chunk % 29 : chunk)
                var offset = 0
                var slice = 0
                while offset < bytes.count {
                    let end = min(offset + 16 * 1024, bytes.count)
                    terminal.feed(bytes[offset..<end])
                    offset = end
                    slice += 1
                    if slice.isMultiple(of: compressEvery) { terminal.compressColdScrollback() }
                }
            }
            terminal.compressColdScrollback()
            report("\(flood.name), pass \(pass)")
        }
    }
    if CommandLine.arguments.contains("--relief") {
        for (label, zone, goal) in [("default zone, goal 0", malloc_default_zone(), 0), ("all zones, goal 1 GiB", nil, 1 << 30)] {
            let released = malloc_zone_pressure_relief(zone, goal)
            report("pressure relief \(label): returned \(released / 1024) KiB")
        }
        sleep(5)
        report("5 s later")
    }
    if CommandLine.arguments.contains("--hold") {
        print("holding pid \(getpid())")
        fflush(stdout)
        sleep(40)
    }
}
