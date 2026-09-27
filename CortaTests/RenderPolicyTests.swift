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

import Metal
import QuartzCore
import Testing

@testable import Corta

/// `RenderPolicy`'s frame-rate ceiling adaptation, checked against
/// `FrameScheduler`'s remembered `preferredFrameRateRange` rather than a
/// live `CAMetalDisplayLink` (which needs a real window and vsync to do
/// anything observable) — `FrameScheduler.preferredFrameRateRange`'s getter
/// returns the last-requested value regardless of whether a link exists
/// (`FrameScheduler.swift`), which is exactly the seam this suite needs.
@MainActor
@Suite("RenderPolicy")
struct RenderPolicyTests {
    private static func makeScheduler() -> FrameScheduler {
        FrameScheduler(metalLayer: CAMetalLayer())
    }

    @Test func constructingWithNoWindowDoesNotCrash() {
        let scheduler = Self.makeScheduler()
        // Real thermal/Low Power Mode state on the test machine is not
        // something this suite controls, so this only asserts init and
        // `apply()` run to completion without crashing on a `nil` window —
        // the deterministic policy behaviour (scrolling) is covered below.
        let policy = RenderPolicy(scheduler: scheduler, window: nil)
        _ = policy
    }

    @Test func scrollingLiftsTheCeilingToUnrestricted() {
        let scheduler = Self.makeScheduler()
        // A restricted starting point the policy would not otherwise
        // choose on its own here, so lifting it is observable.
        scheduler.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 10, preferred: 5)
        let policy = RenderPolicy(scheduler: scheduler, window: nil)

        policy.scrollingStateChanged(true)
        #expect(scheduler.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)
    }

    @Test func endingTheScrollReAppliesTheNonScrollingPolicy() {
        let scheduler = Self.makeScheduler()
        let policy = RenderPolicy(scheduler: scheduler, window: nil)

        // A value neither "scrolling" nor any real non-scrolling policy
        // state would land on, so seeing it gone after `false` proves the
        // transition re-ran `apply()` rather than merely leaving the
        // scrolling override in place.
        scheduler.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 12345, preferred: 1)
        policy.scrollingStateChanged(true)
        #expect(scheduler.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)

        scheduler.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 12345, preferred: 1)
        policy.scrollingStateChanged(false)
        #expect(scheduler.preferredFrameRateRange.maximum != 12345)
    }

    @Test func repeatedIdenticalScrollStateDoesNotReapplyUnnecessarily() {
        let scheduler = Self.makeScheduler()
        let policy = RenderPolicy(scheduler: scheduler, window: nil)
        policy.scrollingStateChanged(true)
        scheduler.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 10, preferred: 5)
        // Reporting "still scrolling" again must not reapply the policy
        // (which would stomp the value set above back to unrestricted) —
        // `RenderPolicy.scrollingStateChanged` guards on an actual change.
        policy.scrollingStateChanged(true)
        #expect(scheduler.preferredFrameRateRange.maximum == 10)
    }
}
