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

/// The panes waiting on the user, most pressing first: sign-in, then permission,
/// then a question, then a wait that names no reason; within each, the one that
/// has waited longest. One entry per pane. A pane leaving the waiting state
/// leaves the queue, and waits from the back if it returns.
///
/// A pane jumped to and still waiting goes behind every pane not jumped to yet,
/// whatever its kind: a program reports its own kind, so one claiming a sign-in
/// that never ends must not hide the others. Once all have been jumped to, the
/// round starts over.
///
/// Pure, in memory, and only ever consulted when the user asks to jump.
nonisolated struct AttentionQueue: Equatable, Sendable {
    /// A waiting pane as it stands now.
    struct Waiting: Equatable, Sendable {
        var id: UUID
        var kind: ProgramStatus.Kind?
    }

    private var entered: [UUID: Int] = [:]
    private var kinds: [UUID: ProgramStatus.Kind?] = [:]
    private var clock = 0
    private var jumpedTo: Set<UUID> = []

    /// Brings the queue up to `waiting`: the newly waiting join with the next
    /// tick, and the rest keep theirs.
    mutating func sync(waiting: [Waiting]) {
        var next: [UUID: Int] = [:]
        var nextKinds: [UUID: ProgramStatus.Kind?] = [:]
        for pane in waiting where next[pane.id] == nil {
            if let existing = entered[pane.id] {
                next[pane.id] = existing
            } else {
                clock += 1
                next[pane.id] = clock
            }
            nextKinds[pane.id] = pane.kind
        }
        entered = next
        kinds = nextKinds
        jumpedTo.formIntersection(next.keys)
    }

    var ordered: [UUID] {
        entered.keys.sorted { left, right in
            let leftJumped = jumpedTo.contains(left), rightJumped = jumpedTo.contains(right)
            if leftJumped != rightJumped { return rightJumped }
            let leftRank = Self.rank(of: kinds[left] ?? nil), rightRank = Self.rank(of: kinds[right] ?? nil)
            if leftRank != rightRank { return leftRank < rightRank }
            return (entered[left] ?? 0) < (entered[right] ?? 0)
        }
    }

    /// The pane to jump to from `current`, recorded as jumped to. A current pane
    /// at the head counts as already there, and so moves back first. Nil if
    /// `current` is the only one waiting, or nothing is.
    mutating func next(from current: UUID?) -> UUID? {
        var order = ordered
        if let current, order.first == current {
            guard order.count > 1 else { return nil }
            markJumped(current)
            // That mark can end the round, which puts a top kind back at the
            // head: `current` is where the user already is, so it is never next.
            order = ordered.filter { $0 != current }
        }
        guard let head = order.first else { return nil }
        markJumped(head)
        return head
    }

    private mutating func markJumped(_ id: UUID) {
        clock += 1
        entered[id] = clock
        jumpedTo.insert(id)
        if jumpedTo.count >= entered.count { jumpedTo.removeAll() }
    }

    private static func rank(of kind: ProgramStatus.Kind?) -> Int {
        switch kind {
        case .auth: 0
        case .permission: 1
        case .question: 2
        case nil: 3
        }
    }
}
