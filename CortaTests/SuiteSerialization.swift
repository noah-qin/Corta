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
import Testing

/// Holds whole suites against each other.
///
/// `.serialized` orders the tests *inside* one suite; it does nothing about
/// two suites running at the same time, which is what a full `CortaTests` run
/// does by default. Some state is shared across suite boundaries and has to
/// be held anyway:
///
/// - **`.metalSerialized`** — `GlyphAtlas` is single-threaded by design, and
///   a full parallel run aborted the runner in `ColorEmojiRenderTests` with a
///   texture descriptor Metal refused. Nothing reproduced it in
///   isolation; the suites that build an atlas now take turns.
///
/// Applied alongside `.serialized`, not instead of it: `@Suite(.serialized,
/// .metalSerialized)`.
struct SuiteSerializationTrait: SuiteTrait, TestTrait, TestScoping {

    let gate: SuiteGate

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // The scope is provided once for the suite and again for each of its
        // cases. Taking the gate for the suite itself would hold it for the
        // suite's whole run and deadlock against the suite's own cases.
        guard testCase != nil else {
            try await function()
            return
        }
        await gate.acquire()
        do {
            try await function()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }
}

extension Trait where Self == SuiteSerializationTrait {
    /// See `SuiteSerializationTrait`.
    static var metalSerialized: Self { Self(gate: .metal) }
}

/// A one-holder gate per kind of shared state. Not a lock: the scope it
/// guards contains `await`, and blocking a cooperative thread there would
/// stall the pool rather than order it.
actor SuiteGate {
    static let metal = SuiteGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
