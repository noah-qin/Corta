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

import Darwin

/// The size of a terminal, in character cells and (optionally) pixels.
///
/// Pixel dimensions are reported to the child through `TIOCSWINSZ`; some
/// programs use them for sixel and image protocols. The app layer
/// (`ViewController.pixelSize(columns:rows:metrics:)`) fills these in from
/// the real device-pixel cell metrics before a size reaches the pty — a
/// Kitty-graphics client such as `kitten icat` refuses outright
/// without them. The zero default here stays truthful for callers with no
/// renderer to measure from (`corta-bench`, the core's own tests).
public struct TerminalSize: Equatable, Sendable {
    public var rows: UInt16
    public var columns: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    /// Pixels per row, or 0 when the app reported no pixel size.
    public var cellPixelHeight: Int {
        rows > 0 ? Int(pixelHeight) / Int(rows) : 0
    }

    /// Pixels per column, or 0 when the app reported no pixel size.
    public var cellPixelWidth: Int {
        columns > 0 ? Int(pixelWidth) / Int(columns) : 0
    }

    public init(
        rows: UInt16 = 24,
        columns: UInt16 = 80,
        pixelWidth: UInt16 = 0,
        pixelHeight: UInt16 = 0
    ) {
        self.rows = rows
        self.columns = columns
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// A `struct winsize` carrying the same dimensions.
    var winsize: Darwin.winsize {
        Darwin.winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: pixelWidth,
            ws_ypixel: pixelHeight
        )
    }

    init(_ ws: Darwin.winsize) {
        self.init(
            rows: ws.ws_row,
            columns: ws.ws_col,
            pixelWidth: ws.ws_xpixel,
            pixelHeight: ws.ws_ypixel
        )
    }
}
