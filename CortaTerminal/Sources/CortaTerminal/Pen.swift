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

/// The current graphic rendition — what SGR sets and what newly written
/// cells inherit.
public struct Pen: Equatable, Sendable {
    public var foreground: Color
    public var background: Color
    public var attributes: CellAttributes
    /// The OSC 8 hyperlink newly written cells belong to, or `.none`.
    ///
    /// Deliberately *not* reset by SGR 0. A hyperlink is not a rendition —
    /// `OSC 8 ; ; ST` is what ends one, and a program that colours the link
    /// text and then resets the colour has not stopped linking.
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

    /// SGR 0. Keeps the hyperlink: see the note on that property.
    public mutating func reset() {
        self = Pen(hyperlink: hyperlink)
    }

    /// A cell carrying `scalar` in the current rendition.
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

    /// What an erase writes.
    ///
    /// Background colour erase (BCE, as in xterm): an erased cell takes the
    /// current background but not the current foreground or attributes —
    /// there is no character to draw, so underlining or colouring it would
    /// invent ink the program did not ask for.
    @inline(__always)
    public var eraseCell: Cell {
        Cell(background: background)
    }
}
