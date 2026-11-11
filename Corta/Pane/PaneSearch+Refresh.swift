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

/// Dropping results the grid no longer holds, continuing a regex sweep that
/// ran out of time (and the bar's text for it), and the toggles, which start
/// a sweep over.
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
        clearOlderSearch()
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

    /// A regex sweep that ran out of time, kept for "Search older lines": the
    /// matches it found and where the next older slice starts. Cleared by
    /// anything that supersedes the sweep.
    struct PendingOlderSearch {
        var matches: [SelectionRange]
        var unsearchedLines: Int
        /// The last row of the next logical line to read, in `totalPushed`
        /// coordinates.
        var resumeRow: Int
        var totalPushed: Int
    }

    /// Keeps a timed-out regex sweep's place, or forgets it when the results
    /// now shown came from a sweep with nothing older left.
    func noteOlderSearch(_ outcome: SweepOutcome, totalPushed: Int) {
        guard let resumeRow = outcome.resumeRow else {
            clearOlderSearch()
            return
        }
        olderSearch = PendingOlderSearch(
            matches: outcome.matches, unsearchedLines: outcome.unsearchedLines,
            resumeRow: resumeRow, totalPushed: totalPushed)
        barModel.canSearchOlder = true
    }

    /// "Search older lines": one more bounded regex sweep from where the last
    /// one ran out of time, over the grid as it is now. Off the main thread,
    /// and cancelled by a new query or the bar closing like any other sweep.
    func searchOlderLines() {
        guard let older = olderSearch, let searchField = field, bar != nil,
            task == nil, let grid = host?.snapshot()
        else { return }
        clearOlderSearch()
        generation &+= 1
        let generation = self.generation
        needsRefresh = false
        let query = searchField.stringValue
        let caseSensitive = self.caseSensitive
        let regex = self.regex
        let timeBudget = regexTimeBudget
        let totalPushed = grid.scrollback.totalPushed
        // Output since the earlier slice shifted every row by the same growth;
        // what has scrolled out of the retained scrollback is gone.
        let growth = ScrollbackCoordinates.growth(from: older.totalPushed, to: totalPushed)
        let lowest = grid.documentRowRange.lowerBound
        let priorMatches = older.matches.compactMap { range -> SelectionRange? in
            let start = range.start.row - growth
            guard start >= lowest else { return nil }
            return SelectionRange(
                start: SelectionPoint(row: start, column: range.start.column),
                end: SelectionPoint(row: range.end.row - growth, column: range.end.column))
        }
        let resumeRow = older.resumeRow - growth
        let unsearchedLines = older.unsearchedLines
        let maxMatches = max(1, Search.defaultMatchLimit - priorMatches.count)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let slice = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex,
                maxMatches: maxMatches, timeBudget: timeBudget, from: resumeRow)
            await MainActor.run {
                self?.applyOlderSlice(
                    slice, priorMatches: priorMatches, unsearchedLines: unsearchedLines,
                    totalPushed: totalPushed, generation: generation)
            }
        }
    }

    /// The older slice comes first, then what the first sweep found; the
    /// count is still a floor while either part left lines unsearched.
    private func applyOlderSlice(
        _ slice: SweepOutcome, priorMatches: [SelectionRange], unsearchedLines: Int,
        totalPushed: Int, generation: Int
    ) {
        var outcome = slice
        outcome.matches.append(contentsOf: priorMatches)
        outcome.unsearchedLines += unsearchedLines
        if outcome.unsearchedLines > 0, case .complete = outcome.status {
            outcome.status = .incomplete
        }
        applyResults(
            outcome, generation: generation,
            scrollsToMatch: priorMatches.isEmpty && !outcome.matches.isEmpty,
            totalPushed: totalPushed)
    }

    /// Forgets a pending "Search older lines": the sweep it belonged to is
    /// superseded, or its results are no longer the ones shown.
    func clearOlderSearch() {
        olderSearch = nil
        barModel.canSearchOlder = false
    }

    /// The bar's count or status text. An incomplete sweep with no matches is
    /// a floor, not a verdict: it says the search covered only part of the
    /// document rather than "No Results".
    func updateCountLabel() {
        guard bar != nil else { return }
        if status == .invalidPattern {
            barModel.countText = L10n.text("search.invalidPattern")
        } else if status == .patternTooSlow {
            barModel.countText = L10n.text("search.patternTooSlow")
        } else if matches.isEmpty {
            if status == .incomplete, field?.stringValue.isEmpty == false {
                // The sweep stopped early: the count is a floor, not a verdict.
                barModel.countText = L10n.text("search.notAllLines")
            } else {
                barModel.countText =
                    field?.stringValue.isEmpty == false ? L10n.text("search.noResults") : ""
            }
        } else if let current = currentMatchIndex {
            // "+" when the sweep stopped early (the match cap, an over-long line, or
            // the time budget): there may be uncounted matches.
            barModel.countText =
                "\(current + 1)/\(matches.count)"
                + (status == .incomplete ? "+" : "")
        }
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
