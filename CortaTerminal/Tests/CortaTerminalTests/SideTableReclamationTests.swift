import Testing

@testable import CortaTerminal

/// P06 — reference-safe reclamation for the hyperlink and grapheme side
/// tables. The safety rule: an id may be recycled only when no cell or pen
/// of the same `Grid` value still carries it; snapshots and the parked
/// alternate screen need no scanning because each `Grid` value owns its
/// table copy (a mutation copy-on-writes away from them).
@Suite("Side-table reclamation (P06)")
struct SideTableReclamationTests {
    private static let linkPrefix = "\u{1B}]8;;"
    private static let linkSuffix = "\u{1B}\\"

    private static func feed(_ terminal: inout Terminal, _ input: String) {
        terminal.feed(Array(input.utf8))
    }

    /// Opens link `url`, writes `text`, closes the link.
    private static func linkSequence(_ url: String, _ text: String) -> String {
        "\(linkPrefix)\(url)\(linkSuffix)\(text)\(linkPrefix)\(linkSuffix)"
    }

    /// Interns `count` distinct links, each overwriting the same cell via
    /// CR, so the interned ids go dead immediately — the table fills without
    /// the screen or scrollback holding any of them.
    private static func fillTableWithDeadLinks(_ terminal: inout Terminal, count: Int, tag: String) {
        for index in 0..<count {
            feed(&terminal, "\(linkPrefix)https://\(tag).test/\(index)\(linkSuffix)x\r")
        }
        feed(&terminal, "\(linkPrefix)\(linkSuffix)")  // close the link
    }

    // MARK: - Table mechanics

    @Test("reclaim keeps live entries resolving and recycles dead slots")
    func reclaimKeepsLiveAndRecyclesDead() throws {
        var table = HyperlinkTable()
        let dead1 = table.intern("https://a.test")
        let live = table.intern("https://b.test")
        let dead2 = table.intern("https://c.test")
        #expect(table.count == 3)
        let liveID = try #require(live)

        #expect(table.reclaim(keeping: [liveID]) == 2)
        #expect(table.url(for: liveID) == "https://b.test")
        #expect(table.url(for: try #require(dead1)) == nil)
        #expect(table.url(for: try #require(dead2)) == nil)
        #expect(table.count == 1)

        // A recycled slot serves a new intern; the live entry is unmoved.
        let recycled = table.intern("https://d.test")
        #expect(recycled == dead1 || recycled == dead2)
        #expect(table.url(for: try #require(recycled)) == "https://d.test")
        #expect(table.url(for: liveID) == "https://b.test")
        // And a re-interned formerly-dead URL is an ordinary new entry.
        let reInterned = table.intern("https://a.test")
        #expect(table.url(for: try #require(reInterned)) == "https://a.test")
        #expect(table.count == 3)
    }

    @Test("a full hyperlink table recovers after a sweep")
    func fullHyperlinkTableRecoversAfterReclaim() throws {
        var table = HyperlinkTable()
        var first: HyperlinkID?
        for index in 0..<HyperlinkTable.capacity {
            let id = table.intern("https://filler.test/\(index)")
            if index == 0 { first = id }
            #expect(id != nil)
        }
        let firstId = try #require(first)
        #expect(table.intern("https://overflow.test") == nil)

        #expect(table.reclaim(keeping: [firstId]) == HyperlinkTable.capacity - 1)
        #expect(table.intern("https://overflow.test") != nil)
        #expect(table.url(for: firstId) == "https://filler.test/0")
    }

    @Test("a full grapheme table recovers after a sweep")
    func fullGraphemeTableRecoversAfterReclaim() throws {
        var table = GraphemeTable()
        var first: GraphemeID?
        for index in 0..<GraphemeTable.capacity {
            let id = table.intern([0x61, UInt32(0x0300 + index % 700), UInt32(index / 700)])
            if index == 0 { first = id }
            #expect(id != nil)
        }
        let firstId = try #require(first)
        let firstCluster = table.scalars(for: firstId)
        #expect(table.intern([0x7A, 0x0301]) == nil)

        #expect(table.reclaim(keeping: [firstId]) == GraphemeTable.capacity - 1)
        #expect(table.intern([0x7A, 0x0301]) != nil)
        #expect(table.scalars(for: firstId) == firstCluster)
    }

    // MARK: - Grid-level reference safety

    @Test("the wire path sweeps a full table instead of never linking again")
    func wirePathRecoversFromAFullTable() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 20)
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "filler")
        #expect(terminal.grid.hyperlinks.count == HyperlinkTable.capacity)

        // Capacity is exhausted, but every filler id is dead: the sweep in
        // `Grid.internHyperlink` must reclaim them rather than failing
        // closed forever (the pre-P06 behaviour).
        Self.feed(&terminal, Self.linkSequence("https://late.test", "LATE"))
        let id = terminal.grid.line(0)[0].hyperlink
        #expect(terminal.grid.hyperlinks.url(for: id) == "https://late.test")
        #expect(terminal.grid.hyperlinks.count < 10)
    }

    @Test("a link held only by the scrollback survives compaction")
    func scrollbackHeldLinkSurvives() throws {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "first")
        // This intern triggers the first sweep; then the linked text is
        // scrolled into history where only the scrollback holds its id.
        Self.feed(&terminal, Self.linkSequence("https://keep.test", "KEEP"))
        Self.feed(&terminal, String(repeating: "\r\n", count: 8))
        let historyIndex = (0..<terminal.grid.scrollback.count).first {
            terminal.grid.scrollback[$0].cells.contains {
                terminal.grid.hyperlinks.url(for: $0.hyperlink) == "https://keep.test"
            }
        }
        let index = try #require(historyIndex, "the linked row must be in the scrollback")

        // Refill: the second sweep runs with the link held only by history.
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "second")
        Self.feed(&terminal, Self.linkSequence("https://late.test", "LATE"))

        let cell = terminal.grid.scrollback[index].cells.first { !$0.hyperlink.isNone }
        #expect(terminal.grid.hyperlinks.url(for: try #require(cell).hyperlink) == "https://keep.test")
    }

    @Test("a link held only by the DECSC-saved pen survives compaction")
    func savedPenLinkSurvives() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 20)
        Self.feed(&terminal, "\(Self.linkPrefix)https://saved.test\(Self.linkSuffix)")
        Self.feed(&terminal, "\u{1B}7")  // DECSC: the pen — and its link — is parked
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "filler")
        // Force the sweep; the saved pen is the only holder of the link.
        Self.feed(&terminal, Self.linkSequence("https://late.test", "LATE"))

        Self.feed(&terminal, "\u{1B}8")  // DECRC restores the linked pen
        Self.feed(&terminal, "Z")
        let cursor = terminal.grid.cursor
        let written = terminal.grid.line(cursor.row)[cursor.column - 1]
        #expect(terminal.grid.hyperlinks.url(for: written.hyperlink) == "https://saved.test")
    }

    @Test("a snapshot's ids still resolve after the live grid compacts and recycles them")
    func snapshotIsolationAcrossCompaction() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 20)
        Self.feed(&terminal, Self.linkSequence("https://snap.test", "SNAP"))
        let snapshot = terminal.grid
        let snapshotID = snapshot.line(0)[0].hyperlink
        #expect(snapshot.hyperlinks.url(for: snapshotID) == "https://snap.test")

        // Kill the live reference (overwrite the linked cell) and fill the
        // table so the next link sweeps and may recycle the old slot.
        Self.feed(&terminal, "\r    \r")
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "filler")
        Self.feed(&terminal, Self.linkSequence("https://late.test", "LATE"))

        // The snapshot is a separate Grid value: its copy of the table is
        // untouched by the live grid's sweep, whatever happened to the slot.
        #expect(snapshot.hyperlinks.url(for: snapshotID) == "https://snap.test")
    }

    @Test("the parked main screen survives a compaction on the alternate screen")
    func parkedScreenSurvivesAlternateScreenCompaction() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 20)
        Self.feed(&terminal, Self.linkSequence("https://main.test", "MAIN"))
        let mainID = terminal.grid.line(0)[0].hyperlink

        Self.feed(&terminal, "\u{1B}[?1049h")
        Self.fillTableWithDeadLinks(&terminal, count: HyperlinkTable.capacity, tag: "alt")
        Self.feed(&terminal, Self.linkSequence("https://late.test", "LATE"))
        Self.feed(&terminal, "\u{1B}[?1049l")

        // The parked grid's own table copy came back with it; the sweep that
        // ran on the alternate screen's copy cannot have touched it.
        #expect(terminal.grid.hyperlinks.url(for: mainID) == "https://main.test")
        #expect(terminal.grid.line(0)[0].hyperlink == mainID)
    }

    // MARK: - Grapheme grid-level

    @Test("grapheme compaction keeps screen and scrollback clusters resolving")
    func graphemeCompactionKeepsLiveClusters() {
        var terminal = Terminal(rows: 5, columns: 40)
        Self.feed(&terminal, "e\u{301}")  // e + combining acute, one cluster
        let id = terminal.grid.line(0)[0].grapheme
        #expect(terminal.grid.graphemes.scalars(for: id) == [0x65, 0x301])
        let snapshot = terminal.grid

        // Overwrite the cell: the cluster id goes dead in the live grid.
        Self.feed(&terminal, "\ry")
        terminal.grid.compactSideTables()
        #expect(terminal.grid.graphemes.count == 0)

        // The snapshot's copy still resolves the old id.
        #expect(snapshot.graphemes.scalars(for: id) == [0x65, 0x301])

        // A new cluster after the sweep may reuse the slot — and resolves
        // to its own scalars, never the dead entry's.
        Self.feed(&terminal, "\u{1B}[2G" + "o\u{308}")  // o + combining diaeresis
        let newID = terminal.grid.line(0)[1].grapheme
        #expect(terminal.grid.graphemes.scalars(for: newID) == [0x6F, 0x308])
        #expect(snapshot.graphemes.scalars(for: id) == [0x65, 0x301])
    }
}
