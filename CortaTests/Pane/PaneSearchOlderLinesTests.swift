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
import Testing

@testable import Corta
@testable import CortaTerminal

/// A regular-expression sweep that runs out of its 500 ms budget has not
/// searched the whole scrollback. The bar must say so rather than "No
/// Results", and "Search older lines" must read the rest — from where the
/// budget ended, over the grid as it is when the user asks, off the main
/// thread.
@MainActor
@Suite(.serialized)
struct PaneSearchOlderLinesTests {
    /// `P04MARKER`-style host with one regex match pushed into the scrollback
    /// and live output below it.
    private func makeHost() -> SearchTestHost {
        let host = SearchTestHost()
        host.print("ERROR needle\n")
        host.print((1...40).map { "filler \($0)\n" }.joined())
        return host
    }

    /// Empty and incomplete is a floor, not a verdict: it says the search
    /// covered only part of the document. Only a completed sweep says No
    /// Results.
    @Test func anIncompleteEmptySweepSaysTheSearchWasPartial() throws {
        let host = makeHost()
        defer { host.search.close() }
        host.search.show()
        try #require(host.search.field).stringValue = "ERROR \\w+"

        host.search.applyResults(
            .init(matches: [], status: .incomplete, unsearchedLines: 2),
            generation: host.search.generation, scrollsToMatch: false, totalPushed: 0)
        #expect(host.search.barModel.countText == L10n.text("search.notAllLines"))
        #expect(host.search.barModel.countText != L10n.text("search.noResults"))
        #expect(!host.search.barModel.canSearchOlder, "nothing older was offered")

        host.search.applyResults(
            .init(matches: [], status: .complete),
            generation: host.search.generation, scrollsToMatch: false, totalPushed: 0)
        #expect(host.search.barModel.countText == L10n.text("search.noResults"))
    }

    /// A sweep that timed out with no match offers the older part, and
    /// pressing the action finds the match the first slice did not reach. The
    /// continuation is a detached sweep like the first one.
    @Test func aTimedOutSweepOffersOlderLinesAndContinuingFindsTheMatch() async throws {
        let host = makeHost()
        defer { host.search.close() }
        host.search.show()
        host.search.regex = true
        // A deterministic timeout: read no line at all, then resume with a
        // budget that covers the document.
        host.search.regexTimeBudget = .zero
        let field = try #require(host.search.field)
        field.stringValue = "ERROR \\w+"
        host.search.updateResults(scrollsToMatch: true)
        #expect(await waitUpTo(5) {
            host.search.task == nil && host.search.status == .incomplete
        })
        #expect(host.search.matches.isEmpty)
        #expect(host.search.barModel.countText == L10n.text("search.notAllLines"))
        #expect(host.search.barModel.canSearchOlder)

        host.search.regexTimeBudget = .seconds(5)
        host.search.searchOlderLines()
        #expect(host.search.task != nil, "the continuation sweeps off the main thread")
        #expect(host.search.matches.isEmpty, "nothing is applied on this turn")

        #expect(await waitUpTo(5) { host.search.matches.count == 1 })
        #expect(host.search.status == .complete)
        #expect(host.search.barModel.countText == "1/1")
        #expect(!host.search.barModel.canSearchOlder)
        #expect(host.scrollOffset > 0, "the match is in the scrollback")
    }

    /// Output arriving between the timed-out slice and the user's click
    /// shifts every row: the older slice and the matches found so far land on
    /// the same text as a fresh sweep of the grid as it is now.
    @Test func continuingAfterOutputLandsOnTheSameLines() async throws {
        let host = SearchTestHost()
        host.print("ERROR oldest\n")
        host.print((1...40).map { "filler \($0)\n" }.joined())
        host.print("ERROR newer\n")
        defer { host.search.close() }
        host.search.show()
        host.search.regex = true
        try #require(host.search.field).stringValue = "ERROR \\w+"
        let grid = try #require(host.snapshot())
        let full = Search.findRegex("ERROR \\w+", in: grid)
        #expect(full.matches.count == 2)
        let newest = try #require(full.matches.last)

        // What a first slice that found the newer match and timed out just
        // below it would have left: the newer match, and where to resume.
        host.search.applyResults(
            .init(
                matches: [newest], status: .incomplete,
                resumeRow: newest.start.row - 1, unsearchedLines: 0),
            generation: host.search.generation, scrollsToMatch: false,
            totalPushed: grid.scrollback.totalPushed)
        #expect(host.search.barModel.canSearchOlder)

        // 30 lines arrive before the user continues.
        host.print((1...30).map { "later \($0)\n" }.joined())
        host.search.regexTimeBudget = .seconds(5)
        #expect(host.search.olderSearch != nil, "pending continuation")
        host.search.searchOlderLines()
        #expect(host.search.task != nil, "continuation started")
        #expect(await waitUpTo(5) { host.search.matches.count == 2 })

        let current = try #require(host.snapshot())
        let expected = Search.findRegex("ERROR \\w+", in: current)
        #expect(host.search.matches == expected.matches)
        #expect(host.search.status == .complete)
        #expect(host.search.barModel.countText == "2/2")
    }

    /// A typed change supersedes the pending continuation like any other
    /// sweep: the offer goes and the old place is not used.
    @Test func aNewQueryDropsTheOlderLinesOffer() throws {
        let host = makeHost()
        defer { host.search.close() }
        host.search.show()
        let field = try #require(host.search.field)
        field.stringValue = "ERROR \\w+"
        let grid = try #require(host.snapshot())
        host.search.applyResults(
            .init(matches: [], status: .incomplete, resumeRow: 0),
            generation: host.search.generation, scrollsToMatch: false,
            totalPushed: grid.scrollback.totalPushed)
        #expect(host.search.olderSearch != nil)
        #expect(host.search.barModel.canSearchOlder)

        field.stringValue = "filler"
        host.search.updateResults(scrollsToMatch: true)
        #expect(host.search.olderSearch == nil)
        #expect(!host.search.barModel.canSearchOlder)
    }

    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = SuspendingClock.now + .seconds(seconds * Double(testTimeoutScale))
        while SuspendingClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
