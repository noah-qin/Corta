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

/// Bounded, interned underline colours. Zero means the cell foreground.
public struct UnderlineColorTable: Sendable {
    public static let capacity = 4095
    private var colors: [UInt16: Color] = [:]
    private var ids: [Color: UInt16] = [:]
    private var nextID: UInt16 = 1
    public init() {}
    public private(set) var reclamationGeneration: UInt64 = 0
    public var count: Int { colors.count }
    public func color(for id: UInt16) -> Color? { colors[id] }
    mutating func intern(_ color: Color) -> UInt16? {
        if color.isDefault { return 0 }
        if let id = ids[color] { return id }
        guard colors.count < Self.capacity else { return nil }
        while colors[nextID] != nil { nextID = nextID == 4095 ? 1 : nextID + 1 }
        let id = nextID
        colors[id] = color
        ids[color] = id
        return id
    }
    mutating func reclaim(keeping live: Set<UInt16>) -> Int {
        let dead = colors.keys.filter { !live.contains($0) }
        if !dead.isEmpty { reclamationGeneration &+= 1 }
        for id in dead {
            if let color = colors.removeValue(forKey: id) { ids[color] = nil }
        }
        return dead.count
    }
}
