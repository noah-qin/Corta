import Testing

@testable import CortaTerminal

/// B04 follow-up — the shared coordinate conversions that replace the
/// hand-derived arithmetic previously duplicated across the render path,
/// selection, search and shell-integration prompt-jumping.
@Suite("Scrollback coordinates")
struct ScrollbackCoordinatesTests {
    @Test("reanchoredRow subtracts the growth, keeping the same absolute row")
    func reanchoredRowSubtractsGrowth() {
        // A selection anchored at document row -100 when totalPushed was
        // 500 (absolute row 400) still names absolute row 400 once
        // totalPushed reaches 550: relative row becomes -150.
        #expect(ScrollbackCoordinates.reanchoredRow(-100, from: 500, to: 550) == -150)
        // A live-screen row (non-negative) re-anchors the same way.
        #expect(ScrollbackCoordinates.reanchoredRow(5, from: 500, to: 550) == -45)
    }

    @Test("reanchoredOffset adds the growth, keeping the same absolute row")
    func reanchoredOffsetAddsGrowth() {
        // scrollOffset 100 lines above the bottom when totalPushed was 500
        // (absolute row 400) still points at absolute row 400 once
        // totalPushed reaches 550: the offset grows to 150.
        #expect(ScrollbackCoordinates.reanchoredOffset(100, from: 500, to: 550) == 150)
    }

    @Test("reanchoredRow and reanchoredOffset are sign-mirrors of each other")
    func rowAndOffsetAreMirrored() {
        // scrollOffset o at total T names absolute row T - o, i.e. relative
        // row -o. Re-anchoring either representation to a later total must
        // land on the same absolute row.
        let total = 1000
        let laterTotal = 1200
        let offset = 300
        let row = -offset
        let reanchoredViaOffset = ScrollbackCoordinates.reanchoredOffset(offset, from: total, to: laterTotal)
        let reanchoredViaRow = ScrollbackCoordinates.reanchoredRow(row, from: total, to: laterTotal)
        #expect(reanchoredViaRow == -reanchoredViaOffset)
        #expect(
            ScrollbackCoordinates.absoluteRow(reanchoredViaRow, totalPushed: laterTotal)
                == ScrollbackCoordinates.viewportTopRow(
                    totalPushed: laterTotal, scrollOffset: reanchoredViaOffset))
    }

    @Test("a total that went backwards shifts by zero, not negative")
    func backwardsTotalShiftsByZero() {
        #expect(ScrollbackCoordinates.reanchoredRow(-50, from: 500, to: 400) == -50)
        #expect(ScrollbackCoordinates.reanchoredOffset(50, from: 500, to: 400) == 50)
    }

    @Test("absoluteRow adds the relative row to the current total")
    func absoluteRowAddsRelativeRow() {
        #expect(ScrollbackCoordinates.absoluteRow(-30, totalPushed: 1000) == 970)
        #expect(ScrollbackCoordinates.absoluteRow(5, totalPushed: 1000) == 1005)
    }

    @Test("viewportTopRow subtracts the offset from the current total")
    func viewportTopRowSubtractsOffset() {
        #expect(ScrollbackCoordinates.viewportTopRow(totalPushed: 1000, scrollOffset: 0) == 1000)
        #expect(ScrollbackCoordinates.viewportTopRow(totalPushed: 1000, scrollOffset: 200) == 800)
    }

    @Test("offset(forRow:totalPushed:) inverts viewportTopRow")
    func offsetForRowInvertsViewportTopRow() {
        let totalPushed = 1000
        for scrollOffset in [0, 1, 200, 999] {
            let row = ScrollbackCoordinates.viewportTopRow(
                totalPushed: totalPushed, scrollOffset: scrollOffset)
            #expect(
                ScrollbackCoordinates.offset(forRow: row, totalPushed: totalPushed) == scrollOffset)
        }
    }

    @Test("relativeRow inverts absoluteRow")
    func relativeRowInvertsAbsoluteRow() {
        let totalPushed = 1000
        for relative in [-500, -1, 0, 1, 23] {
            let absolute = ScrollbackCoordinates.absoluteRow(relative, totalPushed: totalPushed)
            #expect(
                ScrollbackCoordinates.relativeRow(absolute, totalPushed: totalPushed) == relative)
        }
    }
}
