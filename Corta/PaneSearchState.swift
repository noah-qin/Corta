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

import AppKit
import CortaTerminal

/// Search UI, task lifetime and scroll anchors belonging to one terminal pane.
@MainActor
final class PaneSearchState {
    var bar: NSGlassEffectView?
    var container: NSGlassEffectContainerView?
    /// The bar sits top-right; it moves to the bottom-right while the cursor
    /// or the current match would sit under it. One of the pair is active.
    var topConstraint: NSLayoutConstraint?
    var bottomConstraint: NSLayoutConstraint?
    var field: NSTextField?
    var matches: [SelectionRange] = []
    var currentMatchIndex: Int?

    /// Absolute row (totalPushed + row), stable while output scrolls.
    var currentMatchAnchor: Int?

    var status: SweepOutcome.Status = .complete
    var matchesTruncated = false
    var task: Task<Void, Never>?
    /// Paired scroll position and scrollback anchor, restored when search closes.
    var previousScrollOffset: Int?
    var previousTotalPushed: Int?
    /// Reject results from superseded sweeps; retain output arriving during a sweep.
    var generation = 0
    var needsRefresh = false
    /// Optional test barrier for deterministic background-sweep races.
    var sweepGate: (@Sendable () -> Void)?
    var caseSensitive = false
    var regex = false
    var keyMonitor: Any?

    struct SweepOutcome: Sendable {
        var matches: [SelectionRange]
        var status: Status

        enum Status: Sendable {
            /// The whole document was searched.
            case complete
            /// The sweep hit the match cap, a line too long to run a pattern
            /// against, or its time budget. The count is a floor.
            case incomplete
            /// The pattern does not compile.
            case invalidPattern
            /// The pattern's shape makes a backtracking engine take
            /// exponential time, so it was refused before it ran.
            case patternTooSlow
        }
    }
}
