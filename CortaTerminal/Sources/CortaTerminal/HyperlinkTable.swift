/// Identifies an OSC 8 hyperlink held in a `HyperlinkTable` (M6.8).
///
/// Zero means "this cell is not part of a hyperlink", which is the
/// overwhelmingly common case and costs nothing to test for — the same shape
/// as `GraphemeID`, for the same reason.
public struct HyperlinkID: Equatable, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = HyperlinkID(rawValue: 0)
    public var isNone: Bool { rawValue == 0 }
}

/// The side table for OSC 8 hyperlink targets.
///
/// URLs are interned, so `ls --hyperlink` over a directory of a thousand
/// files costs one entry per distinct target rather than one per cell.
///
/// Capacity is capped at what a cell's 11 spare bits can address; beyond
/// that `intern` returns `nil` and the cell simply carries no link — but
/// `Grid` first sweeps unreferenced entries (`reclaim(keeping:)`, P06), so
/// a long `ls --hyperlink` session recovers instead of never linking again.
/// Every unbounded input needs a cap (`SECURITY.md` §3), and this one is fed
/// directly by the byte stream — a program that emits a fresh URL per cell
/// would otherwise grow this table without limit.
///
/// The table stores what the stream sent, and nothing here decides that a
/// URL is safe to open: the scheme allowlist is applied at the hand-off to
/// `NSWorkspace`, where it can be checked against the real target the user
/// was shown (`SECURITY.md` §2.4).
public struct HyperlinkTable: Sendable {
    public static let capacity = Int(Cell.maximumHyperlinkID)
    /// A URL longer than this is not a URL, it is an attempt to make the
    /// table's memory grow per link.
    static let maximumURLLength = 2048

    /// `nil` is a reclaimed slot (P06), exactly as in `GraphemeTable`: a
    /// live entry's id (its index) never moves, which is what makes
    /// recycling the dead ones safe.
    private var urls: ContiguousArray<String?> = []
    private var ids: [String: HyperlinkID] = [:]
    /// Reclaimed slots a future `intern` reuses before growing the table.
    private var freeSlots: [Int] = []

    public init() {}

    /// Live entries; reclaimed slots no longer count.
    public var count: Int { urls.count - freeSlots.count }

    /// Returns the id for `url`, interning it if it is new, or `nil` when
    /// the table is full or the URL is over-long. A reclaimed slot is reused
    /// before the table grows.
    public mutating func intern(_ url: String) -> HyperlinkID? {
        guard !url.isEmpty, url.utf8.count <= Self.maximumURLLength else { return nil }
        if let existing = ids[url] { return existing }
        if let slot = freeSlots.popLast() {
            urls[slot] = url
            let id = HyperlinkID(rawValue: UInt16(slot + 1))
            ids[url] = id
            return id
        }
        guard urls.count < Self.capacity else { return nil }
        urls.append(url)
        let id = HyperlinkID(rawValue: UInt16(urls.count))
        ids[url] = id
        return id
    }

    /// The URL behind an id, or `nil` for `.none`, unknown ids and
    /// reclaimed slots.
    public func url(for id: HyperlinkID) -> String? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < urls.count else { return nil }
        return urls[index]
    }

    /// Drops every entry whose id is not in `live`, freeing its string and
    /// returning its slot to the pool. Returns how many slots were freed.
    ///
    /// SAFETY (P06): `live` must contain every id any cell or pen of this
    /// grid can still carry — a recycled id resolves to an *unrelated* URL
    /// for a stale holder, which for a hyperlink is a destination-spoofing
    /// bug, not a cosmetic one. The caller (`Grid.liveHyperlinkIDs`)
    /// computes the complete set; snapshots need no scanning because each
    /// `Grid` value carries its own copy of this table.
    @discardableResult
    public mutating func reclaim(keeping live: Set<HyperlinkID>) -> Int {
        var freed = 0
        for index in urls.indices {
            guard let entry = urls[index],
                !live.contains(HyperlinkID(rawValue: UInt16(index + 1)))
            else { continue }
            urls[index] = nil
            ids[entry] = nil
            freeSlots.append(index)
            freed += 1
        }
        return freed
    }

    public mutating func removeAll() {
        urls.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
        freeSlots.removeAll(keepingCapacity: true)
    }
}
