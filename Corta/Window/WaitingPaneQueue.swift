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
    private(set) var paneIDs: [UUID] = []

    @discardableResult
    mutating func update(_ paneID: UUID, blocked: Bool) -> Bool {
        if blocked {
            guard !paneIDs.contains(paneID) else { return false }
            paneIDs.append(paneID)
        } else {
            guard let index = paneIDs.firstIndex(of: paneID) else { return false }
            paneIDs.remove(at: index)
        }
        return true
    }

    func isEnabled(agentStatus: Bool) -> Bool { agentStatus && !paneIDs.isEmpty }

    /// A single current waiter has no successor; an outsider starts at the head.
    func next(after current: UUID?, agentStatus: Bool) -> UUID? {
        guard isEnabled(agentStatus: agentStatus) else { return nil }
        guard let current, let index = paneIDs.firstIndex(of: current) else { return paneIDs.first }
        guard paneIDs.count > 1 else { return nil }
        return paneIDs[(index + 1) % paneIDs.count]
    }
}
