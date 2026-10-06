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

struct GPUFrameFeedbackTests {
    @Test func missingFeedbackExpiresWithoutAnyFurtherFrameCallback() {
        let feedback = GPUFrameFeedback()
        let start = ContinuousClock.now
        _ = feedback.begin(now: start)
        #expect(!feedback.hasExpired(now: start + .seconds(1)))
        #expect(feedback.hasExpired(now: start + .seconds(2)))
    }

    @Test func completingANewerFrameCannotHideAnOlderHungFrame() {
        let feedback = GPUFrameFeedback()
        let start = ContinuousClock.now
        let first = feedback.begin(now: start)
        let second = feedback.begin(now: start + .seconds(1))
        feedback.complete(second)
        #expect(feedback.hasExpired(now: start + .seconds(2)))
        feedback.complete(first)
        #expect(!feedback.hasPending)
        #expect(!feedback.hasExpired(now: start + .seconds(10)))
    }

    @Test func aReplacedTrackerIgnoresTheOldQueuesFeedback() {
        let old = GPUFrameFeedback()
        let oldID = old.begin()
        let replacement = GPUFrameFeedback()
        let currentID = replacement.begin()
        old.complete(oldID)
        #expect(replacement.hasPending)
        replacement.complete(currentID)
        #expect(!replacement.hasPending)
    }
}
