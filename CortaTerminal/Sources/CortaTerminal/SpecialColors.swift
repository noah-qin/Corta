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

/// OSC 5/105's five named slots (bold, underline, blink, reverse, italic).
/// No themed default: an unset slot means ordinary SGR rendering, so empty
/// `overrides` is "nothing overridden", not "all black".
public struct SpecialColors: Sendable, Equatable {
    public enum Slot: UInt8, CaseIterable, Sendable {
        case bold = 0
        case underline = 1
        case blink = 2
        case reverse = 3
        case italic = 4
    }

    public internal(set) var overrides: [Slot: (red: UInt8, green: UInt8, blue: UInt8)] = [:]

    public init() {}

    public func color(at slot: Slot) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        overrides[slot]
    }

    mutating func setOverride(_ slot: Slot, to color: (red: UInt8, green: UInt8, blue: UInt8)) {
        overrides[slot] = color
    }

    mutating func resetAllOverrides() {
        overrides.removeAll()
    }

    mutating func resetOverride(_ slot: Slot) {
        overrides[slot] = nil
    }

    public static func == (lhs: SpecialColors, rhs: SpecialColors) -> Bool {
        guard lhs.overrides.count == rhs.overrides.count else { return false }
        for (slot, color) in lhs.overrides {
            guard let other = rhs.overrides[slot], other == color else { return false }
        }
        return true
    }
}
