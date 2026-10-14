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



extension Grid {
    // MARK: - Side-table reclamation

    /// Sweeps unreferenced entries when full; without it a session that met
    /// `capacity` URLs would never link again.
    public mutating func internHyperlink(_ url: String) -> HyperlinkID? {
        if let id = hyperlinks.intern(url) { return id }
        guard hyperlinks.count >= HyperlinkTable.capacity,
            Self.sideTableSweepAllowed(&hyperlinkSweepDeferral)
        else { return nil }
        sideTableSweeps += 1
        let freed = hyperlinks.reclaim(keeping: liveHyperlinkIDs())
        Self.deferSideTableSweep(&hyperlinkSweepDeferral, freed: freed, capacity: HyperlinkTable.capacity)
        return hyperlinks.intern(url)
    }

    /// A sweep scans every cell on screen and in scrollback under the session
    /// lock. When the table is full of entries still in use it frees nothing,
    /// and sweeping again on every new link or mark — `ls --hyperlink -R`
    /// over a big tree — froze the pane. So a sweep that freed under a quarter
    /// of the table skips the next quarter-table's worth of failed interns:
    /// at most one scan per that many, and what fails meanwhile goes unlinked
    /// or unmarked, as when full.
    static func sideTableSweepAllowed(_ deferral: inout Int) -> Bool {
        guard deferral > 0 else { return true }
        deferral -= 1
        return false
    }

    static func deferSideTableSweep(_ deferral: inout Int, freed: Int, capacity: Int) {
        let quarter = capacity / 4
        deferral = freed < quarter ? quarter : 0
    }

    /// Cells on screen and in scrollback, plus both pens (a saved pen restores
    /// into the current one). The parked main screen and snapshots hold their
    /// own copy of the table, so scanning only this value is reference-safe.
    func liveHyperlinkIDs() -> Set<HyperlinkID> {
        var live: Set<HyperlinkID> = [pen.hyperlink]
        if let savedPen { live.insert(savedPen.hyperlink) }
        for row in 0..<rows {
            for cell in lines[row].cells where !cell.hyperlink.isNone {
                live.insert(cell.hyperlink)
            }
        }
        live.formUnion(scrollback.liveHyperlinkIDs())
        live.remove(.none)
        return live
    }

    /// Cells only: no pen carries a cluster.
    func liveGraphemeIDs() -> Set<GraphemeID> {
        var live: Set<GraphemeID> = []
        for row in 0..<rows {
            for cell in lines[row].cells where !cell.grapheme.isNone {
                live.insert(cell.grapheme)
            }
        }
        live.formUnion(scrollback.liveGraphemeIDs())
        return live
    }

    /// Tests only; in production each table sweeps when `intern` is full.
    mutating func compactSideTables() {
        graphemes.reclaim(keeping: liveGraphemeIDs())
        hyperlinks.reclaim(keeping: liveHyperlinkIDs())
    }
}
