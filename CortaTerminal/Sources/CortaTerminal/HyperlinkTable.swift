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
/// that `intern` returns `nil` and the cell simply carries no link. Every
/// unbounded input needs a cap (`SECURITY.md` §3), and this one is fed
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

    private var urls: ContiguousArray<String> = []
    private var ids: [String: HyperlinkID] = [:]

    public init() {}

    public var count: Int { urls.count }

    /// Returns the id for `url`, interning it if it is new, or `nil` when
    /// the table is full or the URL is over-long.
    public mutating func intern(_ url: String) -> HyperlinkID? {
        guard !url.isEmpty, url.utf8.count <= Self.maximumURLLength else { return nil }
        if let existing = ids[url] { return existing }
        guard urls.count < Self.capacity else { return nil }
        urls.append(url)
        let id = HyperlinkID(rawValue: UInt16(urls.count))
        ids[url] = id
        return id
    }

    /// The URL behind an id, or `nil` for `.none` and unknown ids.
    public func url(for id: HyperlinkID) -> String? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < urls.count else { return nil }
        return urls[index]
    }

    public mutating func removeAll() {
        urls.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
    }
}
