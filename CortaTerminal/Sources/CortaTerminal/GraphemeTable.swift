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
/// returns `nil` and the caller keeps the base scalar alone — but `Grid`
/// first sweeps unreferenced entries (`reclaim(keeping:)`, P06), so a
/// long-lived session recovers instead of degrading permanently. Every
/// unbounded input needs a cap (`SECURITY.md` §3), and this one is fed
/// directly by the byte stream.
///
/// M2.1 populates this table as zero-width scalars join the previously
/// written cell's cluster; ZWJ sequences arrive with M3.6.
public struct GraphemeTable: Sendable {
    public static let capacity = Int(UInt16.max) - 1

    /// `nil` is a reclaimed slot (P06): its id was referenced nowhere when
    /// `reclaim(keeping:)` ran, and a later `intern` may hand the slot to an
    /// unrelated cluster. Ids are indices into this array, so a *live* entry
    /// never moves — that stability is what makes slot reuse safe.
    private var clusters: ContiguousArray<[UInt32]?> = []
    private var ids: [[UInt32]: GraphemeID] = [:]
    /// Reclaimed slots a future `intern` reuses before growing the table
    /// further. Order is irrelevant: any free slot is a valid id.
    private var freeSlots: [Int] = []

    public init() {}

    /// Live entries; reclaimed slots no longer count.
    public var count: Int { clusters.count - freeSlots.count }

    /// Returns the id for `scalars`, interning it if it is new, or `nil` if
    /// the table is full. A reclaimed slot is reused before the table grows.
    public mutating func intern(_ scalars: [UInt32]) -> GraphemeID? {
        if let existing = ids[scalars] { return existing }
        if let slot = freeSlots.popLast() {
            clusters[slot] = scalars
            let id = GraphemeID(rawValue: UInt16(slot + 1))
            ids[scalars] = id
            return id
        }
        guard clusters.count < Self.capacity else { return nil }
        clusters.append(scalars)
        let id = GraphemeID(rawValue: UInt16(clusters.count))
        ids[scalars] = id
        return id
    }

    /// The scalars behind an id, or `nil` for `.none`, unknown ids and
    /// reclaimed slots.
    public func scalars(for id: GraphemeID) -> [UInt32]? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < clusters.count else { return nil }
        return clusters[index]
    }

    /// Drops every entry whose id is not in `live`, freeing its memory and
    /// returning its slot to the pool. Returns how many slots were freed.
    ///
    /// SAFETY (P06): `live` must contain every id any cell of this grid can
    /// still carry — screen, scrollback, parked alternate screen included.
    /// An id recycled while still referenced would afterwards resolve to an
    /// unrelated cluster: a use-after-free in table form. The caller
    /// (`Grid.liveGraphemeIDs`) computes the complete set; snapshots need no
    /// scanning because each `Grid` value carries its own copy of this
    /// table, so reclaiming here copy-on-writes away from every snapshot.
    @discardableResult
    public mutating func reclaim(keeping live: Set<GraphemeID>) -> Int {
        var freed = 0
        for index in clusters.indices {
            guard let entry = clusters[index],
                !live.contains(GraphemeID(rawValue: UInt16(index + 1)))
            else { continue }
            clusters[index] = nil
            ids[entry] = nil
            freeSlots.append(index)
            freed += 1
        }
        return freed
    }

    public mutating func removeAll() {
        clusters.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
        freeSlots.removeAll(keepingCapacity: true)
    }
}
