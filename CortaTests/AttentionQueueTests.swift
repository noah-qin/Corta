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

    @Test func onlyBlockedWaitsDoneErrorAndUnknownDoNot() {
        #expect(AttentionQueue.isWaiting(state: .blocked))
        for state: ProgramStatus.State? in [.done, .error, .idle, .working, .unknown, nil] {
            #expect(!AttentionQueue.isWaiting(state: state))
        }
    }
}
