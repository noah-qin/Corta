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
        let a = UUID(), b = UUID(), third = UUID()
        #expect(queue.sync(waiting: [a]) == [a])
        #expect(queue.sync(waiting: [a, b]) == [a, b])
        #expect(queue.sync(waiting: [b, third, a]) == [a, b, third])
        #expect(queue.sync(waiting: [a, b, third]) == [a, b, third], "a repeated sample is not a new wait")
        let ordered = queue.sync(waiting: [a, b, third])
        #expect(queue.deferHead(of: ordered) == a)
        #expect(queue.sync(waiting: [a, b, third]) == [b, third, a])
        #expect(queue.sync(waiting: [b, third]) == [b, third], "leaving the wait drops it")
        #expect(queue.sync(waiting: [b, third, a]) == [b, third, a], "coming back waits behind")
        #expect(queue.deferHead(of: []) == nil)
    }

    @Test func kindPriorityOrdersTheQueueAndAJumpStillReachesEveryKind() {
        var queue = AttentionQueue()
        let question = UUID(), permission = UUID(), auth = UUID()
        let priorities = [auth: 0, permission: 1, question: 2]
        #expect(queue.sync(waiting: [question], priorities: priorities) == [question])
        #expect(queue.sync(waiting: [question, permission], priorities: priorities) == [permission, question])
        var ordered = queue.sync(waiting: [question, permission, auth], priorities: priorities)
        #expect(ordered == [auth, permission, question], "sign-in first, however late it came")
        #expect(queue.deferHead(of: ordered) == auth)
        ordered = queue.sync(waiting: [question, permission, auth], priorities: priorities)
        #expect(ordered == [permission, question, auth], "a jumped sign-in that keeps waiting goes behind")
        #expect(queue.deferHead(of: ordered) == permission)
        ordered = queue.sync(waiting: [question, permission, auth], priorities: priorities)
        #expect(ordered == [question, auth, permission])
        #expect(queue.deferHead(of: ordered) == question)
        ordered = queue.sync(waiting: [question, permission, auth], priorities: priorities)
        #expect(ordered == [auth, permission, question], "every one seen: the round starts over")
        #expect(queue.deferHead(of: ordered) == auth)
        #expect(queue.sync(waiting: [question, auth], priorities: priorities) == [question, auth])
        #expect(queue.sync(waiting: [question, permission, auth], priorities: priorities)
            == [permission, question, auth], "a newcomer is not behind the jumped one")
    }

    @Test func onlyBlockedWaitsDoneErrorAndUnknownDoNot() {
        #expect(AttentionQueue.isWaiting(state: .blocked))
        for state: ProgramStatus.State? in [.done, .error, .idle, .working, .unknown, nil] {
            #expect(!AttentionQueue.isWaiting(state: state))
        }
    }
}
