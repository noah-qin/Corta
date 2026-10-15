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

import Compression
import CortaTerminal
import Darwin
import Dispatch
import Foundation

// How fast bytes become grid: the parse throughput and its corpora, and the scrollback codecs.

// A representative corpus: plain text, SGR colour changes, cursor moves —
// the shape of real shell output (`ls --color`, log lines), not a
// pathological worst case and not a best case of bare ASCII either.
func makeCorpus(targetBytes: Int) -> [UInt8] {
    var text = ""
    text.reserveCapacity(targetBytes + 256)
    var counter = 0
    while text.utf8.count < targetBytes {
        text += "\u{1B}[32mdrwxr-xr-x\u{1B}[0m  \u{1B}[34muser\u{1B}[0m  file-\(counter).log\r\n"
        counter += 1
    }
    return Array(text.utf8)
}

func benchmarkParseThroughput() {
    let corpus = makeCorpus(targetBytes: 64 * 1_048_576)

    struct CountingPerformer: ParserPerformer {
        var printableBytes = 0
        mutating func print(_ scalar: UInt32) { printableBytes &+= 1 }
        mutating func printASCII(_ bytes: ArraySlice<UInt8>) { printableBytes &+= bytes.count }
        mutating func execute(_ control: UInt8) {}
    }

    var parser = Parser()
    var counter = CountingPerformer()
    var start = DispatchTime.now()
    parser.parse(corpus, performer: &counter)
    var elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print(
        "parser-only throughput: \(String(format: "%.1f", throughput(corpus.count, elapsedSeconds: elapsedSeconds))) MiB/s "
            + "(\(counter.printableBytes) printable bytes observed)"
    )

    var gridOnly = Terminal(rows: 50, columns: 200, scrollbackLimit: 0)
    start = DispatchTime.now()
    gridOnly.feed(corpus)
    elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print(
        "parser + grid throughput: \(String(format: "%.1f", throughput(corpus.count, elapsedSeconds: elapsedSeconds))) MiB/s "
            + "(scrollback disabled)"
    )

    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 10_000)
    start = DispatchTime.now()
    terminal.feed(corpus)
    elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

    let mibps = throughput(corpus.count, elapsedSeconds: elapsedSeconds)
    print("core feed throughput: \(String(format: "%.1f", mibps)) MiB/s (\(corpus.count) bytes in \(String(format: "%.3f", elapsedSeconds))s)")
}

// Synthetic workloads; never captured terminal output.
func benchmarkUnicodeCorpora() {
    struct Counter: ParserPerformer {
        var count = 0
        mutating func print(_ scalar: UInt32) { count &+= 1 }
        mutating func printASCII(_ bytes: ArraySlice<UInt8>) { count &+= bytes.count }
        mutating func execute(_ byte: UInt8) {}
    }
    for (name, line) in [
        ("ASCII", "\u{1B}[32mdrwxr-xr-x\u{1B}[0m user file.log\r\n"),
        ("CJK", "\u{1B}[32m终端性能测试 日本語の文章 输出历史与搜索\u{1B}[0m\r\n"),
        ("emoji", "┌────┐ │ ✅ 🚀 👩🏽‍💻 🌈 │ └────┘\r\n"),
        ("AI CLI", "\u{1B}[36m│ 分析代码 ✅\u{1B}[0m changes: +42 −12 ├── src/main.swift 🚀\r\n")
    ] {
        let unit = Array(line.utf8)
        let corpus = Array(repeating: unit, count: max(1, 8 * 1_048_576 / unit.count)).flatMap { $0 }
        let sampleOption = CommandLine.arguments.firstIndex(of: "--unicode-samples")
        let requested = sampleOption.flatMap { $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 5
        let sampleCount = min(20, max(1, requested))
        for mode in 0..<3 {
            var samples: [Double] = []
            var checksum = 0
            for iteration in 0...sampleCount {
                var parser = Parser(), counter = Counter()
                var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: mode == 1 ? 0 : 10_000)
                let start = DispatchTime.now().uptimeNanoseconds
                if mode == 0 { parser.parse(corpus, performer: &counter) }
                else { terminal.feed(corpus) }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if iteration > 0 { samples.append(seconds) }
                checksum &+= counter.count + terminal.grid.scrollback.count + terminal.grid.cursor.column
                    + Int(terminal.grid.line(0)[0].scalar)
            }
            samples.sort()
            let rate = throughput(corpus.count, elapsedSeconds: samples[samples.count / 2])
            let low = throughput(corpus.count, elapsedSeconds: samples.last!)
            let high = throughput(corpus.count, elapsedSeconds: samples.first!)
            print("unicode \(name) \(["parser", "grid", "feed"][mode]): \(String(format: "%.1f", rate)) MiB/s checksum \(checksum) (n=\(sampleCount), range \(String(format: "%.1f", low))–\(String(format: "%.1f", high)), one warmup)")
        }

    }
}

func benchmarkCompressionCodecs() {
    for name in ["SGR ls", "log", "CJK"] {
        var terminal = Terminal(rows: 1, columns: 120, scrollbackLimit: 100_000)
        for row in 0..<100_001 {
            let text: String
            switch name {
            case "SGR ls": text = "\u{1B}[\(31 + row % 7)mdrwxr-xr-x\u{1B}[0m user file-\(row).log " + String(repeating: "abc", count: 29)
            case "log": text = "2026-10-11 INFO request \(row) status=\(200 + row % 5) latency=\(row % 997)ms " + String(repeating: "data", count: 16)
            default: text = "记录 \(row) 终端历史压缩测试 日本語の文章 输出历史与搜索 " + String(repeating: "中文", count: 14)
            }
            terminal.feed(Array((text + "\r\n").utf8))
        }
        for (codecName, codec) in [("LZ4", COMPRESSION_LZ4), ("LZFSE", COMPRESSION_LZFSE)] {
            for shuffled in [false, true] {
                var rawBytes = 0, encodedBytes = 0
                var encodeNS: UInt64 = 0, decodeNS: UInt64 = 0
                terminal.grid.scrollback.withCellBatches { cells in
                    let raw = Array(UnsafeRawBufferPointer(cells))
                    guard !raw.isEmpty else { return }
                    let count = cells.count, stride = MemoryLayout<Cell>.stride
                    let start = DispatchTime.now().uptimeNanoseconds
                    var source = raw
                    if shuffled {
                        source = [UInt8](repeating: 0, count: raw.count)
                        for byte in 0..<stride { for cell in 0..<count { source[byte * count + cell] = raw[cell * stride + byte] } }
                    }
                    var output = [UInt8](repeating: 0, count: source.count + 65536)
                    let size = source.withUnsafeBufferPointer { src in output.withUnsafeMutableBufferPointer { dst in
                        compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, codec)
                    } }
                    encodeNS += DispatchTime.now().uptimeNanoseconds - start
                    precondition(size > 0)
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    var decoded = [UInt8](repeating: 0, count: raw.count)
                    let sizeOut = output.withUnsafeBufferPointer { src in decoded.withUnsafeMutableBufferPointer { dst in
                        compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, size, nil, codec)
                    } }
                    if shuffled {
                        var unshuffled = [UInt8](repeating: 0, count: raw.count)
                        for byte in 0..<stride { for cell in 0..<count { unshuffled[cell * stride + byte] = decoded[byte * count + cell] } }
                        decoded = unshuffled
                    }
                    decodeNS += DispatchTime.now().uptimeNanoseconds - decodeStart
                    precondition(sizeOut == raw.count && decoded == raw)
                    rawBytes += raw.count; encodedBytes += size
                }
                print("compression \(name) 100k rows \(codecName) \(shuffled ? "shuffled" : "raw"): \(String(format: "%.2f", Double(rawBytes) / Double(encodedBytes)))x encode \(String(format: "%.1f", throughput(rawBytes, elapsedSeconds: Double(encodeNS) / 1e9))) decode \(String(format: "%.1f", throughput(rawBytes, elapsedSeconds: Double(decodeNS) / 1e9))) MiB/s including shuffle/scratch; raw bytes \(rawBytes)")
            }
        }
    }
}

extension Array where Element == UInt8 {
    /// `self` repeated until at least `count` bytes.
    func repeated(toCount count: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count + self.count)
        while result.count < count { result.append(contentsOf: self) }
        return result
    }
}

/// `--profile-cjk`: a CJK flood to profile, with no measurement of its own.
func profileCJKFlood() {
    let bytes = Array(String(repeating: "\u{1B}[32m终端性能测试 日本語の文章 输出历史与搜索\u{1B}[0m\r\n", count: 10000).utf8)
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 10000)
    for _ in 0..<2000 { terminal.feed(bytes) }
    print(terminal.grid.scrollback.totalPushed)
}

