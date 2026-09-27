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
import Foundation
import Testing

@testable import Corta

/// A live window drag must not hammer the child with `TIOCSWINSZ` /
/// `SIGWINCH` per mouse motion — N events coalesce to a bounded number of
/// deliveries, and the final size always wins.
@MainActor
struct ResizeDebouncerTests {
    /// N = 100 coalesced resize events (a drag across 100 distinct sizes)
    /// must produce exactly 1 delivery: the final size.
    @Test func oneHundredDragEventsCoalesceToOneFinalDelivery() async throws {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        for i in 0..<100 {
            debouncer.resize(to: TerminalSize(rows: 24, columns: UInt16(80 + i)), coalesce: true)
        }
        #expect(sent.isEmpty)  // nothing leaves during the drag
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent == [TerminalSize(rows: 24, columns: 179)])
    }

    /// Non-coalesced events (initial layout, programmatic resizes) go through
    /// synchronously, one delivery per event.
    @Test func immediateEventsAreNotDebounced() {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        for i in 0..<3 {
            debouncer.resize(to: TerminalSize(rows: 24, columns: UInt16(80 + i)), coalesce: false)
        }
        #expect(sent.count == 3)
    }

    /// Ending the drag delivers the pending size immediately, and the timer
    /// must not deliver it a second time when it expires.
    @Test func flushDeliversPendingSizeOnce() async throws {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        for i in 0..<100 {
            debouncer.resize(to: TerminalSize(rows: 24, columns: UInt16(80 + i)), coalesce: true)
        }
        debouncer.flush()
        #expect(sent == [TerminalSize(rows: 24, columns: 179)])
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.count == 1)  // no double delivery
    }

    /// A coalesced burst followed by an immediate event delivers the
    /// immediate one now and drops the stale pending size.
    @Test func immediateEventCancelsPendingCoalescedSize() async throws {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        debouncer.resize(to: TerminalSize(rows: 24, columns: 100), coalesce: true)
        debouncer.resize(to: TerminalSize(rows: 24, columns: 80), coalesce: false)
        #expect(sent == [TerminalSize(rows: 24, columns: 80)])
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.count == 1)
    }

    /// Characterization: trailing-only means a pause longer than the
    /// window delivers the size current at that pause — a slow drag is not
    /// starved, it just never delivers a superseded size.
    @Test func pauseLongerThanWindowDeliversSizeAtThePause() async throws {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        debouncer.resize(to: TerminalSize(rows: 24, columns: 100), coalesce: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sent == [TerminalSize(rows: 24, columns: 100)])
        debouncer.resize(to: TerminalSize(rows: 24, columns: 90), coalesce: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sent == [TerminalSize(rows: 24, columns: 100), TerminalSize(rows: 24, columns: 90)])
    }

    /// Flushing with nothing pending delivers nothing — `endLiveResize`
    /// fires on drags that produced no size change too.
    @Test func flushWithNothingPendingIsANoOp() async throws {
        var sent: [TerminalSize] = []
        let debouncer = ResizeDebouncer(delay: 0.05) { sent.append($0) }
        debouncer.flush()
        try await Task.sleep(for: .milliseconds(150))
        #expect(sent.isEmpty)
    }
}
