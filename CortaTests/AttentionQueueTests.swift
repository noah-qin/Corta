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

/// The order panes wait in, and the jump through them.
struct AttentionQueueTests {
    private let auth = UUID(), permission = UUID(), question = UUID(), unnamed = UUID()

    private var all: [AttentionQueue.Waiting] {
        [
            .init(id: question, kind: .question), .init(id: permission, kind: .permission),
            .init(id: unnamed, kind: nil), .init(id: auth, kind: .auth),
        ]
    }

    @Test func signInThenPermissionThenQuestionThenNoReason() {
        var queue = AttentionQueue()
        queue.sync(waiting: all)
        #expect(queue.ordered == [auth, permission, question, unnamed])
    }

    @Test func withinAKindTheLongestWaitingLeads() {
        let first = UUID(), second = UUID()
        var queue = AttentionQueue()
        queue.sync(waiting: [.init(id: first, kind: .permission)])
        queue.sync(waiting: [.init(id: first, kind: .permission), .init(id: second, kind: .permission)])
        #expect(queue.ordered == [first, second])
        // Reported order is not arrival order.
        queue.sync(waiting: [.init(id: second, kind: .permission), .init(id: first, kind: .permission)])
        #expect(queue.ordered == [first, second])
    }

    @Test func aMoreUrgentKindPassesAnEarlierWait() {
        var queue = AttentionQueue()
        queue.sync(waiting: [.init(id: question, kind: .question)])
        queue.sync(waiting: [.init(id: question, kind: .question), .init(id: auth, kind: .auth)])
        #expect(queue.ordered == [auth, question])
    }

    /// `state=blocked` alone: a kind changing mid-wait keeps its place in time.
    @Test func aChangedKindKeepsItsEntryTime() {
        let first = UUID(), second = UUID()
        var queue = AttentionQueue()
        queue.sync(waiting: [.init(id: first, kind: .question)])
        queue.sync(waiting: [.init(id: first, kind: .question), .init(id: second, kind: .permission)])
        queue.sync(waiting: [.init(id: first, kind: .permission), .init(id: second, kind: .permission)])
        #expect(queue.ordered == [first, second])
    }

    @Test func aJumpedPaneStillWaitingGoesBehindTheOthers() {
        var queue = AttentionQueue()
        queue.sync(waiting: all)
        #expect(queue.next(from: nil) == auth)
        #expect(queue.ordered == [permission, question, unnamed, auth])
        #expect(queue.next(from: auth) == permission)
        #expect(queue.next(from: permission) == question)
    }

    /// A program claiming a sign-in for ever cannot keep the others from view.
    @Test func oneSessionCannotBlockTheRest() {
        var queue = AttentionQueue()
        queue.sync(waiting: all)
        var visited: [UUID] = []
        var current: UUID?
        for _ in 0..<4 {
            current = queue.next(from: current)
            if let current { visited.append(current) }
            queue.sync(waiting: all)
        }
        #expect(Set(visited) == Set(all.map(\.id)))
    }

    @Test func theRoundStartsOverOnceEveryPaneHasHadItsTurn() {
        var queue = AttentionQueue()
        queue.sync(waiting: all)
        var current: UUID?
        for _ in 0..<4 { current = queue.next(from: current) }
        #expect(queue.ordered.first == auth)
    }

    @Test func leavingAndReturningWaitsFromTheBack() {
        let first = UUID(), second = UUID()
        var queue = AttentionQueue()
        queue.sync(waiting: [.init(id: first, kind: .question), .init(id: second, kind: .question)])
        queue.sync(waiting: [.init(id: second, kind: .question)])
        queue.sync(waiting: [.init(id: second, kind: .question), .init(id: first, kind: .question)])
        #expect(queue.ordered == [second, first])
    }

    @Test func nothingWaitingMeansNoWhereToGo() {
        var queue = AttentionQueue()
        #expect(queue.next(from: nil) == nil)
        #expect(queue.next(from: UUID()) == nil)
    }

    @Test func theOnlyWaitingPaneAlreadyFocusedStays() {
        var queue = AttentionQueue()
        queue.sync(waiting: [.init(id: auth, kind: .auth)])
        #expect(queue.next(from: auth) == nil)
        #expect(queue.next(from: nil) == auth)
    }

    /// A focused pane that is not waiting goes straight to the head.
    @Test func aFocusedPaneOutsideTheQueueStartsAtTheHead() {
        var queue = AttentionQueue()
        queue.sync(waiting: all)
        #expect(queue.next(from: UUID()) == auth)
    }
}
