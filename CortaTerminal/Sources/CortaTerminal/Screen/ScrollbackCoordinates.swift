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

/// Document/viewport coordinate conversions, shared by the renderer,
/// selection, search, the scrolled-away viewport and prompt jumping so the
/// arithmetic is written once.
///
/// Everything is measured against `Scrollback.totalPushed`, which only grows
/// (`.count` saturates; a raw offset drifts as the bottom moves) —
/// `DESIGN.md` §3.1.
///
/// Two sign conventions name the same absolute row: a document row is
/// `totalPushed + relativeRow` (negative in scrollback), while `scrollOffset`
/// counts lines *above* the bottom (`totalPushed - scrollOffset`). Growth is
/// subtracted from the first and added to the second, hence two functions.
public enum ScrollbackCoordinates {
    /// Never negative: `newTotal < oldTotal` (a reset, stale data) is no growth.
    @inlinable
    public static func growth(from oldTotal: Int, to newTotal: Int) -> Int {
        max(0, newTotal - oldTotal)
    }

    /// A stored document row, kept on the same absolute row as the total grows.
    @inlinable
    public static func reanchoredRow(_ row: Int, from oldTotal: Int, to newTotal: Int) -> Int {
        row - growth(from: oldTotal, to: newTotal)
    }

    /// A lines-above-the-bottom value (`scrollOffset`), kept on the same row.
    @inlinable
    public static func reanchoredOffset(_ offset: Int, from oldTotal: Int, to newTotal: Int) -> Int {
        offset + growth(from: oldTotal, to: newTotal)
    }

    @inlinable
    public static func absoluteRow(_ relativeRow: Int, totalPushed: Int) -> Int {
        totalPushed + relativeRow
    }

    @inlinable
    public static func viewportTopRow(totalPushed: Int, scrollOffset: Int) -> Int {
        totalPushed - scrollOffset
    }

    /// The `scrollOffset` that puts `row` at the top of the viewport.
    @inlinable
    public static func offset(forRow row: Int, totalPushed: Int) -> Int {
        totalPushed - row
    }

    @inlinable
    public static func relativeRow(_ absoluteRow: Int, totalPushed: Int) -> Int {
        absoluteRow - totalPushed
    }
}
