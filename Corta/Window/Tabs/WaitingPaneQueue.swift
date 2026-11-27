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

/// Arrival order of live blocked panes, one UUID per pane, in memory only.
/// Call on status events and owner teardown; kind and program text are not inputs.
nonisolated struct WaitingPaneQueue: Equatable, Sendable {
    private struct Wait: Equatable, Sendable {
        var paneID: UUID
        var startedAt: Date
    }

    private var waits: [Wait] = []
    var paneIDs: [UUID] { waits.map(\.paneID) }

    func startedAt(for paneID: UUID) -> Date? {
        waits.first { $0.paneID == paneID }?.startedAt
    }

    @discardableResult
    mutating func update(_ paneID: UUID, blocked: Bool, at now: Date) -> Bool {
        if blocked {
            guard startedAt(for: paneID) == nil else { return false }
            waits.append(Wait(paneID: paneID, startedAt: now))
        } else {
            guard let index = waits.firstIndex(where: { $0.paneID == paneID }) else { return false }
            waits.remove(at: index)
        }
        return true
    }

    func isEnabled(agentStatus: Bool) -> Bool { agentStatus && !waits.isEmpty }

    /// A single current waiter has no successor; an outsider starts at the head.
    func next(after current: UUID?, agentStatus: Bool) -> UUID? {
        guard isEnabled(agentStatus: agentStatus) else { return nil }
        guard let current, let index = waits.firstIndex(where: { $0.paneID == current }) else {
            return waits.first?.paneID
        }
        guard waits.count > 1 else { return nil }
        return waits[(index + 1) % waits.count].paneID
    }
}
