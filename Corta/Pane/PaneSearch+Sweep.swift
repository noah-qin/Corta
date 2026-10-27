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

/// The scan itself: pure and `nonisolated`, run by the debounced sweep tasks.
extension PaneSearch {
    /// One sweep in either mode, pure and `nonisolated` so both detached
    /// tasks share it.
    nonisolated static func sweep(
        _ query: String, in grid: Grid, caseSensitive: Bool, regex: Bool
    ) -> SweepOutcome {
        guard regex else {
            let matches = Search.find(
                query, in: grid, caseSensitive: caseSensitive,
                maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled })
            return SweepOutcome(
                matches: matches,
                status: matches.count >= Search.defaultMatchLimit ? .incomplete : .complete)
        }
        // An invalid or catastrophic-backtracking pattern is its own state, not
        // "no results": the search never ran.
        guard Search.isValidRegex(query, caseSensitive: caseSensitive) else {
            return SweepOutcome(matches: [], status: .invalidPattern)
        }
        guard !Search.isCatastrophic(query) else {
            return SweepOutcome(matches: [], status: .patternTooSlow)
        }
        let result = Search.findRegex(
            query, in: grid, caseSensitive: caseSensitive,
            maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled })
        return SweepOutcome(
            matches: result.matches,
            status: result.isIncomplete ? .incomplete : .complete)
    }

    /// The match nearest a remembered absolute row: the exact line may be
    /// evicted or rewritten, and a neighbour beats losing the place.
    nonisolated static func index(
        closestTo anchor: Int?, in matches: [SelectionRange], totalPushed: Int
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let anchor else { return matches.count - 1 }
        var best = 0
        var bestDistance = Int.max
        for (index, match) in matches.enumerated() {
            let distance = abs(
                ScrollbackCoordinates.absoluteRow(match.start.row, totalPushed: totalPushed) - anchor)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
