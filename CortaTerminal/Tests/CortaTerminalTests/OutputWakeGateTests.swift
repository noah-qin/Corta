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

import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// The reader-to-frame wake: one main-actor hop per frame, none lost.
@Suite("Output wake gate")
struct OutputWakeGateTests {
    @Test("only the first batch since a take asks for a wake")
    func firstBatchWakes() {
        let gate = OutputWakeGate()
        #expect(gate.noteOutput())
        #expect(!gate.noteOutput())
        #expect(!gate.noteOutput())
    }

    @Test("the frame's take reports output once and re-arms the wake")
    func takeReArms() {
        let gate = OutputWakeGate()
        #expect(!gate.takePending())
        _ = gate.noteOutput()
        #expect(gate.takePending())
        #expect(!gate.takePending())
        #expect(gate.noteOutput())
    }

    @Test("every batch stamps the reader's clock, woken or not")
    func stampsEveryBatch() {
        let gate = OutputWakeGate()
        #expect(gate.lastOutputUptimeNanoseconds == 0)
        _ = gate.noteOutput()
        let first = gate.lastOutputUptimeNanoseconds
        #expect(first > 0)
        Thread.sleep(forTimeInterval: 0.002)
        #expect(!gate.noteOutput())
        #expect(gate.lastOutputUptimeNanoseconds > first)
    }

    /// Every wake is a false-to-true edge and every successful take its
    /// matching true-to-false edge, so under any interleaving the wakes equal
    /// the takes that found output, plus one if output is still pending: none
    /// lost (a batch left with no wake coming) and none extra.
    @Test("a reader racing a frame loses no wake and adds none")
    func concurrentWakesMatchTakes() {
        let gate = OutputWakeGate()
        let batches = 200_000
        let wakes = Atomic(0)
        let readerDone = Atomic(false)
        let reader = Thread {
            for _ in 0..<batches where gate.noteOutput() {
                wakes.add(1, ordering: .relaxed)
            }
            readerDone.store(true, ordering: .releasing)
        }
        reader.start()
        var takesWithOutput = 0
        while !readerDone.load(ordering: .acquiring) {
            if gate.takePending() { takesWithOutput += 1 }
        }
        let stillPending = gate.takePending()
        #expect(wakes.load(ordering: .relaxed) == takesWithOutput + (stillPending ? 1 : 0))
        #expect(wakes.load(ordering: .relaxed) < batches)
    }
}
