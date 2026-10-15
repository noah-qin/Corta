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

import Darwin
import Synchronization
import Testing
import CortaTerminal

/// Heap allocations made by the calling thread while `body` runs, counted
/// through libmalloc's `malloc_logger` hook.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private nonisolated(unsafe) var countedThread: pthread_t?
private let allocationCount = Atomic<Int>(0)
private let allocationLock = Mutex(())

private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE
    guard type & 2 != 0, let thread = countedThread, pthread_equal(thread, pthread_self()) != 0 else { return }
    allocationCount.add(1, ordering: .relaxed)
}

private func allocations(during body: () -> Void) -> Int {
    allocationLock.withLock { _ in
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
}

#if DEBUG
private let isOptimized = false
#else
private let isOptimized = true
#endif

/// The parse → grid half of the hot path allocates nothing once warm
/// (`PERFORMANCE.md` §3). Unoptimised generics allocate everywhere, so the
/// suite runs only in an optimised build: `ci.yml` runs it under `-c release`.
@Suite(.serialized, .enabled(if: isOptimized, "allocation counts are only meaningful optimised"))
struct HotPathAllocationTests {
    static let ascii: [UInt8] = Array(repeating: Array("The quick brown fox jumps over the lazy dog 0123456789 ".utf8), count: 2).flatMap { $0 }
    static func lines(_ count: Int, _ line: [UInt8]) -> [UInt8] {
        Array((0..<count).map { _ in line + [0x0D, 0x0A] }.joined())
    }

    func measure(scrollback: Int, warm: [UInt8], stream: [UInt8]) -> Int {
        var terminal = Terminal(rows: 40, columns: 120, scrollbackLimit: scrollback)
        terminal.feed(warm)
        terminal.feed(stream)
        let count = allocations { terminal.feed(stream) }
        return count
    }

    @Test func overwriteInPlace() {
        let frame = Array("\u{1B}[H".utf8) + Self.lines(39, Self.ascii)
        #expect(measure(scrollback: 0, warm: frame, stream: frame) == 0)
    }

    @Test func scrollWithoutHistory() {
        let text = Self.lines(400, Self.ascii)
        #expect(measure(scrollback: 0, warm: text, stream: text) == 0)
    }

    @Test func scrollIntoHistory() {
        let text = Self.lines(2_000, Self.ascii)
        let count = measure(scrollback: 100_000, warm: text, stream: text)
        #expect(count <= 2_000 / 256 * 4 + 8)
    }

    @Test func colouredText() {
        let line = Array("\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;5;208morange\u{1B}[0m \u{1B}[38;2;10;200;30mtrue\u{1B}[0m plain text here".utf8)
        let text = Self.lines(400, line)
        #expect(measure(scrollback: 0, warm: text, stream: text) == 0)
    }

    @Test func cursorAndErase() {
        let ops = Array("\u{1B}[10;10H\u{1B}[2Kabc\u{1B}[5A\u{1B}[3Cxyz\u{1B}[J\u{1B}[1;1H\u{1B}[K\u{1B}[?25l\u{1B}[?25h".utf8)
        let stream = Array(repeating: ops, count: 200).flatMap { $0 }
        #expect(measure(scrollback: 0, warm: stream, stream: stream) == 0)
    }

    @Test func wideText() {
        let line = Array("中文宽字符测试 日本語 한국어 mixed ASCII".utf8)
        let text = Self.lines(400, line)
        #expect(measure(scrollback: 0, warm: text, stream: text) == 0)
    }

    @Test func clusters() {
        let line = Array("e\u{301} 👍🏽 👨‍👩‍👧 🇨🇳 flags and marks".utf8)
        let text = Self.lines(400, line)
        #expect(measure(scrollback: 0, warm: text, stream: text) == 0)
    }
}
