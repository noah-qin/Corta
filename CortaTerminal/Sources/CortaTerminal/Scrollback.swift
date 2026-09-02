/// The history of rows that have scrolled off the top of the screen.
///
/// Rows are packed into batches of up to `batchSize`, each batch one shared
/// `ContiguousArray<Cell>` arena that its rows are appended into once and
/// never mutated again. This is not the obvious design — the obvious one is
/// one array per row — and the reason is measured, not guessed
/// (`PERFORMANCE.md` §4, M4 footprint step): at 100k 120-column lines, a
/// `ContiguousArray<Cell>` grown one column at a time (matching how a shell
/// actually writes a line, one `write(_:)` call per character) lands at
/// capacity 158 for 120 cells used — roughly 57 MB of pure growth headroom
/// across 100k rows — and 100k separate heap allocations carry their own
/// per-allocation overhead on top of that, together accounting for most of
/// the 265.7 MB measured against a 183 MB floor of actual cell data.
/// Batching amortizes both costs: packing rows into an arena as they are
/// pushed needs no growth headroom (the row's exact length is already
/// known), and one arena serves up to `batchSize` rows instead of one each.
///
/// This is safe here specifically because scrollback rows are immutable
/// once pushed — "held for a long time and never edited again," as this
/// file's own comment said before batching existed. The live screen
/// (`Grid.lines`) is not batched: those rows are actively written to,
/// column by column, and batching would force exactly the repacking-per-edit
/// cost this design avoids.
///
/// Batches themselves form a FIFO: a new batch is appended once the current
/// one reaches `batchSize` rows, and the oldest batch is dropped once every
/// one of its rows has aged out of `limit`. Eviction is still O(1) per row
/// (`headSkip` advances by one), and dropping a whole batch happens only
/// once every `batchSize` pushes, amortizing to O(1) as well — the number
/// of batches alive at once is bounded by `limit`, so the FIFO's own
/// bookkeeping array never grows large enough for its cost to matter.
///
/// Scrollback is never written to disk: it routinely holds credentials
/// echoed by something that should not have echoed them (`SECURITY.md` §5).
public struct Scrollback: Sendable {
    public static let defaultLimit = 10_000

    public let limit: Int

    /// Rows per batch. Capped so a single batch's arena reallocation isn't
    /// itself a large copy, and floored to `limit` so a small scrollback
    /// still gets at least one batch that can fill and rotate rather than
    /// growing one arena forever.
    private let batchSize: Int

    private struct RowSpan: Sendable {
        var start: Int32
        var length: Int32
        var wrapped: Bool
    }

    /// One shared arena and the spans within it that are its rows, in
    /// insertion order. Sealed at `batchSize` rows; never mutated after.
    private struct Batch: Sendable {
        var arena: ContiguousArray<Cell> = []
        var rows: ContiguousArray<RowSpan> = []
    }

    /// Oldest first, newest (still-filling) last. A plain FIFO, not a ring:
    /// the array itself is small (bounded by `limit / batchSize`) and its
    /// own reallocation cost on `removeFirst()` is negligible next to the
    /// cell data it stops needing to copy per row.
    private var batches: ContiguousArray<Batch> = []

    /// Rows already evicted from the oldest (`batches.first`) batch.
    private var headSkip = 0

    public private(set) var count = 0

    public init(limit: Int = defaultLimit) {
        self.limit = max(0, limit)
        self.batchSize = self.limit == 0 ? 1 : max(1, min(256, self.limit))
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == limit }

    /// Oldest first: index 0 is the line furthest back in history.
    public subscript(index: Int) -> Line {
        guard index >= 0, index < count else { return Line() }
        let global = index + headSkip
        let batchIndex = global / batchSize
        let rowIndex = global % batchSize
        guard batchIndex < batches.count, rowIndex < batches[batchIndex].rows.count else { return Line() }
        let batch = batches[batchIndex]
        let span = batch.rows[rowIndex]
        let start = Int(span.start)
        let end = start + Int(span.length)
        return Line(wrapped: span.wrapped, cells: batch.arena[start..<end])
    }

    /// The history, oldest first. Allocates; for dumps and diagnostics, not
    /// for the render path.
    public var lines: [Line] {
        (0..<count).map { self[$0] }
    }

    public mutating func push(_ line: Line) {
        guard limit > 0 else { return }
        var line = line
        line.trimTrailingBlanks()

        if batches.isEmpty || batches[batches.count - 1].rows.count >= batchSize {
            batches.append(Batch())
        }
        let tailIndex = batches.count - 1
        let start = Int32(batches[tailIndex].arena.count)
        batches[tailIndex].arena.append(contentsOf: line.cells)
        batches[tailIndex].rows.append(
            RowSpan(start: start, length: Int32(line.count), wrapped: line.wrapped))

        if count < limit {
            count += 1
        } else {
            // Full: evict the oldest row. Once the whole head batch has
            // aged out, drop its arena and move on to the next.
            headSkip += 1
            if headSkip >= batches[0].rows.count {
                batches.removeFirst()
                headSkip = 0
            }
        }
    }

    /// Testing hook (`@testable`, internal not private): the number of live
    /// batches, to assert the FIFO stays bounded rather than growing with
    /// total lines ever pushed.
    var batchCount: Int { batches.count }

    /// ED 3, and anything else that discards history.
    public mutating func removeAll() {
        batches.removeAll(keepingCapacity: true)
        headSkip = 0
        count = 0
    }
}
