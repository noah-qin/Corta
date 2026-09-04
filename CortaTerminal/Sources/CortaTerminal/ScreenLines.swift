import Synchronization

/// Process-wide, so every `ScreenLines` ever constructed — across every
/// pane, every alternate-screen swap, every resize — gets a value no other
/// one has. `ScreenLines.generation` reads it once at construction.
private let nextScreenLinesGeneration = Atomic<UInt64>(0)

/// Logical screen rows backed by a circular buffer.
///
/// Full-screen scrolling is the dominant operation during sustained output.
/// Keeping a head index turns it from `rows - 1` `Line` assignments per
/// newline into one slot reset and one index increment, while callers keep
/// using ordinary zero-based row coordinates.
struct ScreenLines: RandomAccessCollection, MutableCollection, Sendable {
    typealias Index = Int
    typealias Element = Line

    private var storage: ContiguousArray<Line>
    private var head = 0

    /// Set once, at construction, to a value no other `ScreenLines` instance
    /// has ever had. `revision(at:)` is only comparable *within* one
    /// generation — `Grid.enterAlternateScreen`/`exitAlternateScreen` swap in
    /// a wholesale-replaced `ScreenLines` whose row revisions restart from
    /// the same small numbers a moment-ago main screen's cache might already
    /// hold, and `Grid+Reflow.swift`'s `lines = ScreenLines(...)` does the
    /// same on a column change. `TerminalRenderer` compares this alongside
    /// `rows`/`columns` to decide a full rebuild is needed, rather than
    /// trusting revisions that look unchanged purely by coincidence across
    /// two unrelated screens (`TerminalRenderer.swift`).
    let generation: UInt64

    /// A monotonic stamp per row, bumped every time that row is touched
    /// through `subscript(position:)._modify` or `rotateUp` — the two (and
    /// only two) chokepoints every `Grid` mutation actually goes through
    /// (`Grid.swift`'s `write`/`erase*`/`scroll*`/`insert*`/`delete*` all
    /// read `lines[row]...` or write `lines[row][...] = ...`, both of which
    /// compile to `_modify`). `TerminalRenderer` reads it as a fast
    /// "did this row change" check instead of comparing full `Line` values
    /// (`PERFORMANCE.md` §3).
    ///
    /// Deliberately a stamp, not a content hash: two `Line`s with the same
    /// stamp are only guaranteed identical because nothing has touched
    /// either since they last shared one (a struct copy, e.g. into a
    /// `session.snapshot()`) — it says "unchanged since", not "equal to".
    /// Different stamps do not imply different content (a row erased back
    /// to the same bytes still gets a fresh stamp) — that is the same
    /// conservative direction the old `Line`-equality diff already erred
    /// in, just cheaper to check.
    private var revisions: ContiguousArray<UInt64>
    private var nextRevision: UInt64 = 0

    /// Rows rotated off the top by `rotateUp`, cumulative for this
    /// generation's lifetime — every whole-screen scroll, with or without
    /// scrollback attached (an alternate screen has none:
    /// `Grid.enterAlternateScreen`). `TerminalRenderer` reads the delta
    /// since its last sync to shift its cache instead of rebuilding every
    /// retained row (`TerminalRenderer.applyScrollShift`). Deliberately not
    /// `Scrollback.totalPushed`: that counter is silent during an alternate
    /// screen (`push` is a no-op against a zero-limit ring), which would
    /// hide a real rotation from the renderer and only cost a missed
    /// optimisation there — but this is the more direct, correct source for
    /// the same fact regardless of which screen is live.
    private(set) var totalRotated: UInt64 = 0

    init(repeating line: Line, count: Int) {
        storage = ContiguousArray(repeating: line, count: count)
        revisions = ContiguousArray(repeating: 0, count: count)
        generation = nextScreenLinesGeneration.wrappingAdd(1, ordering: .relaxed).newValue
    }

    init(_ lines: ContiguousArray<Line>) {
        storage = lines
        revisions = ContiguousArray(repeating: 0, count: lines.count)
        generation = nextScreenLinesGeneration.wrappingAdd(1, ordering: .relaxed).newValue
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    subscript(position: Int) -> Line {
        get { storage[physicalIndex(position)] }
        set {
            let index = physicalIndex(position)
            storage[index] = newValue
            stamp(index)
        }
        _modify {
            let index = physicalIndex(position)
            yield &storage[index]
            stamp(index)
        }
    }

    /// The row's current revision stamp — see the property doc above.
    func revision(at position: Int) -> UInt64 {
        revisions[physicalIndex(position)]
    }

    @inline(__always)
    private mutating func stamp(_ physicalIndex: Int) {
        nextRevision &+= 1
        revisions[physicalIndex] = nextRevision
    }

    /// Rotates logical rows upward and clears the rows opened at the bottom.
    mutating func rotateUp(_ count: Int) {
        guard !storage.isEmpty else { return }
        let clamped = Swift.min(Swift.max(0, count), storage.count)
        for _ in 0..<clamped {
            storage[head] = Line()
            stamp(head)
            head += 1
            if head == storage.count { head = 0 }
        }
        totalRotated &+= UInt64(clamped)
    }

    mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Line {
        materialize()
        let before = storage.count
        storage.append(contentsOf: newElements)
        // These rows are about to be seen for the first time by whatever
        // triggered the append (always a dimension change — `Grid.resize` —
        // which forces a full rebuild on its own by changing `rows`), so the
        // stamp only has to keep `revisions` the same length as `storage`,
        // not mean anything in particular.
        revisions.append(contentsOf: repeatElement(0, count: storage.count - before))
    }

    mutating func removeFirst(_ count: Int) {
        materialize()
        storage.removeFirst(count)
        revisions.removeFirst(count)
    }

    mutating func removeLast(_ count: Int) {
        materialize()
        storage.removeLast(count)
        revisions.removeLast(count)
    }

    private func physicalIndex(_ logical: Int) -> Int {
        precondition(logical >= 0 && logical < storage.count)
        let index = head + logical
        return index < storage.count ? index : index - storage.count
    }

    private mutating func materialize() {
        guard head != 0 else { return }
        let reorderedRevisions = ContiguousArray((0..<storage.count).map { revisions[physicalIndex($0)] })
        storage = ContiguousArray(self)
        revisions = reorderedRevisions
        head = 0
    }
}
