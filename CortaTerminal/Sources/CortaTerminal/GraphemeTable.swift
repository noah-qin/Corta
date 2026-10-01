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

/// Zero, the common case, means a single scalar — free to test.
public struct GraphemeID: Equatable, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = GraphemeID(rawValue: 0)
    public var isNone: Bool { rawValue == 0 }
}

/// Clusters too large for a cell's scalar (D05), interned: a screen of one
/// emoji is one entry. Capped (`SECURITY.md` §3), with unreferenced entries
/// swept before giving up and keeping the base scalar alone.
public struct GraphemeTable: Sendable {
    public static let capacity = Int(UInt16.max) - 1

    /// Scalars one cell keeps. Unicode's stream-safe format allows 30
    /// non-starters in a row (UAX #15 §13); a ZWJ family emoji is under a
    /// dozen. Uncapped, each mark copied the whole cluster into a new entry:
    /// 65 534 combining accents on one letter, 130 KB of output, interned
    /// about 8.6 GB.
    public static let maximumClusterScalars = 32

    /// `nil` is a reclaimed slot; a live id never moves, which makes reuse safe.
    private var clusters: ContiguousArray<[UInt32]?> = []
    private var ids: [[UInt32]: GraphemeID] = [:]
    private var freeSlots: [Int] = []

    public init() {}

    public var count: Int { clusters.count - freeSlots.count }

    /// `nil` when full.
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

    public func scalars(for id: GraphemeID) -> [UInt32]? {
        let index = Int(id.rawValue) - 1
        guard index >= 0, index < clusters.count else { return nil }
        return clusters[index]
    }

    /// Returns the slots freed. SAFETY: `live` must hold every id any cell can
    /// still carry — otherwise a use-after-free in table form. Snapshots keep
    /// their own copy.
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
