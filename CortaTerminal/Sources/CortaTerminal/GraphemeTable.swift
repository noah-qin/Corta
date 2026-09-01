/// Identifies a grapheme cluster held in a `GraphemeTable`.
///
/// Zero means "this cell is exactly one scalar", which is the overwhelmingly
/// common case and costs nothing to test for.
public struct GraphemeID: Equatable, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = GraphemeID(rawValue: 0)
    public var isNone: Bool { rawValue == 0 }
}

/// The side table for grapheme clusters that do not fit in a cell's single
/// scalar — combining marks, ZWJ emoji sequences (`DESIGN.md` §2.3).
///
/// Clusters are interned, so a screen full of the same emoji costs one entry.
/// Capacity is capped at `UInt16.max - 1` entries; beyond that `intern`
/// returns `nil` and the caller keeps the base scalar alone. Every unbounded
/// input needs a cap (`SECURITY.md` §3), and this one is fed directly by the
/// byte stream.
///
/// M2.1 populates this table as zero-width scalars join the previously
/// written cell's cluster; ZWJ sequences arrive with M3.6.
public struct GraphemeTable: Sendable {
    public static let capacity = Int(UInt16.max) - 1

    private var clusters: ContiguousArray<[UInt32]> = []
    private var ids: [[UInt32]: GraphemeID] = [:]

    public init() {}

    public var count: Int { clusters.count }

    /// Returns the id for `scalars`, interning it if it is new, or `nil` if
    /// the table is full.
    public mutating func intern(_ scalars: [UInt32]) -> GraphemeID? {
        if let existing = ids[scalars] { return existing }
        guard clusters.count < Self.capacity else { return nil }
        clusters.append(scalars)
        let id = GraphemeID(rawValue: UInt16(clusters.count))
        ids[scalars] = id
        return id
    }

    /// The scalars behind an id, or `nil` for `.none` and unknown ids.
    public func scalars(for id: GraphemeID) -> [UInt32]? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < clusters.count else { return nil }
        return clusters[index]
    }

    public mutating func removeAll() {
        clusters.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
    }
}
