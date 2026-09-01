/// The history of rows that have scrolled off the top of the screen.
///
/// A ring buffer with a fixed line cap. Eviction is O(1) — one slot is
/// overwritten — and the storage is allocated once and never reallocated,
/// which is what makes a terminal that has seen a million lines of training
/// output cost the same as one that has seen a thousand
/// (`PERFORMANCE.md` §4).
///
/// Rows are trimmed of trailing blanks on the way in. They are held for a
/// long time and never edited again, so this is the moment to pay for it
/// (`DESIGN.md` §2.3).
///
/// Scrollback is never written to disk: it routinely holds credentials
/// echoed by something that should not have echoed them (`SECURITY.md` §5).
public struct Scrollback: Sendable {
    /// Rows, not bytes. The memory that follows depends on how full they
    /// are, because rows are variable length.
    public static let defaultLimit = 10_000

    public let limit: Int

    /// The ring. Its count never exceeds `limit`, whatever is pushed.
    private(set) var storage: ContiguousArray<Line> = []

    /// Index of the oldest line in `storage`.
    private var head = 0

    public private(set) var count = 0

    public init(limit: Int = defaultLimit) {
        self.limit = max(0, limit)
        storage.reserveCapacity(min(self.limit, 1024))
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == limit }

    /// Oldest first: index 0 is the line furthest back in history.
    public subscript(index: Int) -> Line {
        guard index >= 0, index < count else { return Line() }
        return storage[(head + index) % limit]
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

        if count < limit {
            storage.append(line)
            count += 1
        } else {
            // Full: overwrite the oldest slot and move the head. No
            // allocation, no shifting, whatever the history size.
            storage[head] = line
            head = (head + 1) % limit
        }
    }

    /// ED 3, and anything else that discards history.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }
}
