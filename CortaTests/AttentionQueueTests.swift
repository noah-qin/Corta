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

struct AttentionQueueTests {
    @Test func oldestWaitsFirstAndAJumpSendsItToTheTail() {
        var queue = AttentionQueue()
        let a = UUID(), b = UUID(), c = UUID()
        #expect(queue.sync(waiting: [a]) == [a])
        #expect(queue.sync(waiting: [a, b]) == [a, b])
        #expect(queue.sync(waiting: [b, c, a]) == [a, b, c])
        #expect(queue.sync(waiting: [a, b, c]) == [a, b, c], "a repeated sample is not a new wait")
        let ordered = queue.sync(waiting: [a, b, c])
        #expect(queue.deferHead(of: ordered) == a)
        #expect(queue.sync(waiting: [a, b, c]) == [b, c, a])
        #expect(queue.sync(waiting: [b, c]) == [b, c], "leaving the wait drops it")
        #expect(queue.sync(waiting: [b, c, a]) == [b, c, a], "coming back waits behind")
        #expect(queue.deferHead(of: []) == nil)
    }

    @Test func permissionQuestionDoneAndAttentionWaitIdleWorkDoesNot() {
        #expect(AttentionQueue.isWaiting(state: .blocked, kind: .permission, attention: false))
        #expect(AttentionQueue.isWaiting(state: .blocked, kind: .question, attention: false))
        #expect(AttentionQueue.isWaiting(state: .idle, kind: .question, attention: false))
        #expect(AttentionQueue.isWaiting(state: .done, kind: nil, attention: false))
        #expect(AttentionQueue.isWaiting(state: .error, kind: nil, attention: false))
        #expect(AttentionQueue.isWaiting(state: .working, kind: nil, attention: true))
        #expect(!AttentionQueue.isWaiting(state: .working, kind: nil, attention: false))
        #expect(!AttentionQueue.isWaiting(state: .idle, kind: nil, attention: false))
        #expect(!AttentionQueue.isWaiting(state: nil, kind: nil, attention: false))
    }
}
