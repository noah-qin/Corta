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

/// Dropping results the grid no longer holds, and the bar's toggles, which
/// start a sweep over.
extension PaneSearch {
    /// The grid the matches were found in is gone: cleared, reset, or
    /// reflowed at a new width, where rows renumber in ways `totalPushed`
    /// does not track. Drops the matches, highlights and count at once,
    /// supersedes a sweep in flight, and — with the bar open — sweeps the
    /// grid as it is now, without waiting out the refresh pacing.
    func invalidateResults() {
        task?.cancel()
        task = nil
        pacingWake?.cancel()
        pacingWake = nil
        needsRefresh = false
        lastSweepLanded = nil
        generation &+= 1
        setMatches([], totalPushed: 0)
        matchesTruncated = false
        currentMatchIndex = nil
        currentMatchAnchor = nil
        status = .complete
        host?.invalidateDisplay()
        guard bar != nil else { return }
        barModel.countText = ""
        placeClearOfContent()
        scheduleBackgroundRefresh()
    }

    /// Flips this pane's case sensitivity and saves it as the default for
    /// bars opened later; other open bars keep theirs.
    func toggleSearchCase() {
        caseSensitive.toggle()
        if !ConfigurationStore.shared.update({ $0.searchCaseSensitive = self.caseSensitive }) {
            // A failed write rolls the config back; match it.
            caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        }
        barModel.caseSensitive = caseSensitive
        // The list changes; re-find the place rather than keep it.
        currentMatchAnchor = nil
        updateResults(scrollsToMatch: true)
    }

    /// As `toggleSearchCase`, for regex mode.
    func toggleSearchRegex() {
        regex.toggle()
        if !ConfigurationStore.shared.update({ $0.searchRegex = self.regex }) {
            // See `toggleSearchCase`.
            regex = ConfigurationStore.shared.configuration.searchRegex
        }
        barModel.regex = regex
        currentMatchAnchor = nil
        updateResults(scrollsToMatch: true)
    }
}
