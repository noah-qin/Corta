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

import Testing

@testable import Corta

/// Without shell integration a task ends after a quiet period, measured from
/// the reader's last batch — output reaches the main actor at most once a
/// frame, and not at all while a hidden pane's frames are paused.
struct TaskNotifierIdleTests {
    private static let second: UInt64 = 1_000_000_000

    @Test func recentOutputOwesTheRestOfTheGrace() throws {
        let remaining = try #require(
            TaskNotifier.remainingGrace(now: 10 * Self.second, lastActivity: 10 * Self.second - Self.second / 2))
        #expect(abs(remaining - 1.0) < 1e-9)
    }

    @Test func aFullGraceOfQuietFinishes() {
        let grace = UInt64(1.5 * Double(Self.second))
        #expect(TaskNotifier.remainingGrace(now: 10 * Self.second, lastActivity: 10 * Self.second - grace) == nil)
        #expect(TaskNotifier.remainingGrace(now: 10 * Self.second, lastActivity: 0) == nil)
    }

    /// A batch stamped after the timer read the clock is still recent.
    @Test func outputStampedAfterNowOwesTheWholeGrace() {
        #expect(TaskNotifier.remainingGrace(now: Self.second, lastActivity: 2 * Self.second) == 1.5)
    }
}
