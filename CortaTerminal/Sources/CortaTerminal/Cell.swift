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

/// One character cell: 16 bytes, no references (`CellTests`, D05), so a row
/// walks without ARC traffic. The OSC 8 id shares `scalar`'s word — a scalar
/// needs 21 of its 32 bits — at the cost of a mask and a shift, measurably
/// nothing next to a larger cell.
public struct Cell: Equatable, Sendable {
    /// Low 21 bits scalar, high 11 hyperlink; private so nothing else assumes it.
    private var packed: UInt32

    private static let scalarBits: UInt32 = 21
    private static let scalarMask: UInt32 = (1 << scalarBits) - 1
    static let maximumHyperlinkID: UInt16 = UInt16((1 << (32 - scalarBits)) - 1)

    /// For a larger cluster, the base character; `grapheme` names the rest.
    @inline(__always)
    public var scalar: UInt32 {
        get { packed & Self.scalarMask }
        set { packed = (packed & ~Self.scalarMask) | (newValue & Self.scalarMask) }
    }

    @inline(__always)
    public var hyperlink: HyperlinkID {
        get { HyperlinkID(rawValue: UInt16(packed >> Self.scalarBits)) }
        set {
            packed =
                (packed & Self.scalarMask) | (UInt32(newValue.rawValue) << Self.scalarBits)
        }
    }

    public var foreground: Color
    public var background: Color
    public var attributes: CellAttributes
    public var grapheme: GraphemeID

    @inline(__always)
    public init(
        scalar: UInt32 = 0x20,
        foreground: Color = .default,
        background: Color = .default,
        attributes: CellAttributes = [],
        grapheme: GraphemeID = .none,
        hyperlink: HyperlinkID = .none
    ) {
        self.packed =
            (scalar & Self.scalarMask) | (UInt32(hyperlink.rawValue) << Self.scalarBits)
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.grapheme = grapheme
    }

    /// What "blank" means everywhere (trimming, erase truncation). A cell erased
    /// under a background colour is not blank.
    public static let blank = Cell()

    @inline(__always)
    public var isBlank: Bool { self == Cell.blank }
}
