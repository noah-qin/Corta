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

    init(repeating line: Line, count: Int) {
        storage = ContiguousArray(repeating: line, count: count)
    }

    init(_ lines: ContiguousArray<Line>) {
        storage = lines
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    subscript(position: Int) -> Line {
        get { storage[physicalIndex(position)] }
        set { storage[physicalIndex(position)] = newValue }
        _modify {
            let index = physicalIndex(position)
            yield &storage[index]
        }
    }

    /// Rotates logical rows upward and clears the rows opened at the bottom.
    mutating func rotateUp(_ count: Int) {
        guard !storage.isEmpty else { return }
        for _ in 0..<Swift.min(Swift.max(0, count), storage.count) {
            storage[head] = Line()
            head += 1
            if head == storage.count { head = 0 }
        }
    }

    mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Line {
        materialize()
        storage.append(contentsOf: newElements)
    }

    mutating func removeFirst(_ count: Int) {
        materialize()
        storage.removeFirst(count)
    }

    mutating func removeLast(_ count: Int) {
        materialize()
        storage.removeLast(count)
    }

    private func physicalIndex(_ logical: Int) -> Int {
        precondition(logical >= 0 && logical < storage.count)
        let index = head + logical
        return index < storage.count ? index : index - storage.count
    }

    private mutating func materialize() {
        guard head != 0 else { return }
        storage = ContiguousArray(self)
        head = 0
    }
}
