// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

/// Zero, the common case, means no link — free to test.
public struct HyperlinkID: Equatable, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = HyperlinkID(rawValue: 0)
    public var isNone: Bool { rawValue == 0 }
}

/// OSC 8 targets, interned: a thousand-file `ls --hyperlink` costs one entry
/// per distinct URL. Capped at what 11 bits address (`SECURITY.md` §3), with
/// unreferenced entries swept first. Stores what the stream sent; the scheme
/// allowlist applies at the hand-off to `NSWorkspace` (§2.4).
public struct HyperlinkTable: Sendable {
    public static let capacity = Int(Cell.maximumHyperlinkID)
    /// Longer is not a URL but a way to grow memory per link.
    static let maximumURLLength = 2048

    /// `nil` is a reclaimed slot; a live id never moves, which makes reuse safe.
    private var urls: ContiguousArray<String?> = []
    private var ids: [String: HyperlinkID] = [:]
    private var freeSlots: [Int] = []

    public init() {}

    public var count: Int { urls.count - freeSlots.count }

    /// `nil` when full or over-long.
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

    public func url(for id: HyperlinkID) -> String? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < urls.count else { return nil }
        return urls[index]
    }

    /// Returns the slots freed. SAFETY: `live` must hold every id a cell or pen
    /// can still carry — a recycled id would send a stale link to an unrelated
    /// URL, a destination spoof. Snapshots keep their own copy.
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
