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
@testable import Corta

struct WaitingPaneQueueTests {
    @Test func arrivalDeduplicationRemovalAndReentry() {
        let first = UUID(), second = UUID(), third = UUID()
        var queue = WaitingPaneQueue()
        #expect(queue.next(after: nil, agentStatus: true) == nil)
        queue.update(first, blocked: true)
        queue.update(second, blocked: true)
        queue.update(first, blocked: true)
        queue.update(third, blocked: false)
        #expect(queue.paneIDs == [first, second])
        queue.update(first, blocked: false)
        #expect(queue.paneIDs == [second])
        queue.update(first, blocked: true)
        #expect(queue.paneIDs == [second, first])
        queue.update(second, blocked: false)
        queue.update(first, blocked: false)
        #expect(queue.paneIDs.isEmpty)
    }

    @Test func navigationWrapsAndHonorsDisabledStatus() {
        let first = UUID(), second = UUID(), outside = UUID()
        var queue = WaitingPaneQueue()
        #expect(!queue.isEnabled(agentStatus: true))
        queue.update(first, blocked: true)
        #expect(queue.next(after: first, agentStatus: true) == nil)
        #expect(queue.next(after: outside, agentStatus: true) == first)
        queue.update(second, blocked: true)
        #expect(queue.next(after: first, agentStatus: true) == second)
        #expect(queue.next(after: second, agentStatus: true) == first)
        #expect(queue.next(after: nil, agentStatus: true) == first)
        #expect(!queue.isEnabled(agentStatus: false))
        #expect(queue.next(after: first, agentStatus: false) == nil)
        #expect(queue.next(after: outside, agentStatus: false) == nil)
    }
}
