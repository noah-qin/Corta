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

    @inlinable
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    @inlinable public static var bold: CellAttributes { CellAttributes(rawValue: 1 << 0) }
    @inlinable public static var dim: CellAttributes { CellAttributes(rawValue: 1 << 1) }
    @inlinable public static var italic: CellAttributes { CellAttributes(rawValue: 1 << 2) }
    @inlinable public static var underline: CellAttributes { CellAttributes(rawValue: 1 << 3) }
    @inlinable public static var blink: CellAttributes { CellAttributes(rawValue: 1 << 4) }
    @inlinable public static var reverse: CellAttributes { CellAttributes(rawValue: 1 << 5) }
    @inlinable public static var invisible: CellAttributes { CellAttributes(rawValue: 1 << 6) }
    @inlinable public static var strikethrough: CellAttributes { CellAttributes(rawValue: 1 << 7) }

    /// Structural, not rendition: set by the grid, masked out of dumps.
    @inlinable public static var wide: CellAttributes { CellAttributes(rawValue: 1 << 8) }
    /// Distinct from a real blank so edits can keep pairs whole.
    @inlinable public static var wideSpacer: CellAttributes { CellAttributes(rawValue: 1 << 9) }
    /// Either half of a wide pair.
    @inlinable public static var widePair: CellAttributes { [.wide, .wideSpacer] }

    /// Bits 10–15 remain reserved.
}
