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

/// Sessions that are waiting on the user, oldest first. One entry per session.
/// Leaving the waiting state drops it. Jumping sends the head to the tail.
nonisolated struct AttentionQueue: Equatable, Sendable {
    private(set) var since: [UUID: Int] = [:]
    private(set) var clock = 0
    /// Jumped to and still waiting: behind every session not jumped to yet,
    /// whatever its kind, so a sign-in that keeps waiting does not hide the rest.
    private(set) var deferred: Set<UUID> = []

    /// `waiting` is the set that is waiting now. Order is kind priority
    /// (lower first), then the time each one entered; jumped sessions last.
    mutating func sync(waiting: [UUID], priorities: [UUID: Int] = [:]) -> [UUID] {
        var next: [UUID: Int] = [:]
        for id in waiting where next[id] == nil {
            if let existing = since[id] {
                next[id] = existing
            } else {
                clock += 1
                next[id] = clock
            }
        }
        since = next
        deferred = deferred.filter { next[$0] != nil }
        return next.sorted {
            let leftDeferred = deferred.contains($0.key), rightDeferred = deferred.contains($1.key)
            if leftDeferred != rightDeferred { return !leftDeferred }
            let left = priorities[$0.key] ?? 3, right = priorities[$1.key] ?? 3
            return left == right ? $0.value < $1.value : left < right
        }.map(\.key)
    }

    /// The head waits again after the others. Returns the id that was jumped.
    /// Once every waiting session has been jumped to, the round starts over.
    mutating func deferHead(of ordered: [UUID]) -> UUID? {
        guard let head = ordered.first, since[head] != nil else { return nil }
        clock += 1
        since[head] = clock
        deferred.insert(head)
        if deferred.count >= since.count { deferred.removeAll() }
        return head
    }

    /// Only a program that says it is blocked on the user waits: a
    /// permission, a question, sign-in. Done, error and a program's own
    /// notification keep their colour in the sidebar and are not queued; a
    /// program that reports no state (no OSC 7501) is never guessed at.
    static func isWaiting(state: ProgramStatus.State?) -> Bool {
        state == .blocked
    }
}
