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

/// What SGR sets and new cells inherit.
public struct Pen: Equatable, Sendable {
    public var foreground: Color
    public var background: Color
    public var attributes: CellAttributes
    /// Not reset by SGR 0: recolouring link text has not ended the link.
    public var hyperlink: HyperlinkID

    public init(
        foreground: Color = .default,
        background: Color = .default,
        attributes: CellAttributes = [],
        hyperlink: HyperlinkID = .none
    ) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.hyperlink = hyperlink
    }

    public mutating func reset() {
        self = Pen(hyperlink: hyperlink)
    }

    @inline(__always)
    public func cell(_ scalar: UInt32) -> Cell {
        Cell(
            scalar: scalar,
            foreground: foreground,
            background: background,
            attributes: attributes,
            hyperlink: hyperlink
        )
    }

    /// BCE: the background only — an erased cell has no character, so colour or
    /// underline would invent ink.
    @inline(__always)
    public var eraseCell: Cell {
        Cell(background: background)
    }
}
