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

/// Rendition flags as a `UInt16`: keeps `Cell` at 16 bytes and makes "styled
/// at all" one comparison.
public struct CellAttributes: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16

    @inline(__always)
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let dim = CellAttributes(rawValue: 1 << 1)
    public static let italic = CellAttributes(rawValue: 1 << 2)
    public static let underline = CellAttributes(rawValue: 1 << 3)
    public static let blink = CellAttributes(rawValue: 1 << 4)
    public static let reverse = CellAttributes(rawValue: 1 << 5)
    public static let invisible = CellAttributes(rawValue: 1 << 6)
    public static let strikethrough = CellAttributes(rawValue: 1 << 7)

    /// Structural, not rendition: set by the grid, masked out of dumps.
    public static let wide = CellAttributes(rawValue: 1 << 8)
    /// Distinct from a real blank so edits can keep pairs whole.
    public static let wideSpacer = CellAttributes(rawValue: 1 << 9)

    /// Bits 10–15 remain reserved.
}
