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

/// The rows that have scrolled off the top of the screen.
///
/// Rows are packed into shared arenas of up to `batchSize`, not one array
/// each — measured (`PERFORMANCE.md` §4): one array per row carried ~57 MB of
/// growth headroom plus 100k allocations' overhead at 100k 120-column lines
/// (265.7 MB against 183 MB of cells). Safe because scrollback rows are never
/// edited after the push; the live screen is not batched for that reason.
/// Eviction is O(1) per row, dropping a batch once all its rows have aged out.
///
/// Never written to disk: it routinely holds echoed credentials
/// (`SECURITY.md` §5).
public struct Scrollback: Sendable {
    public static let defaultLimit = 10_000

    public let limit: Int

    /// Capped so an arena reallocation is not a large copy; at most `limit`
    /// so a small scrollback still rotates instead of growing one arena.
    private let batchSize: Int

    private struct RowSpan: Sendable {
        var start: Int32
        var length: Int32
        var wrapped: Bool
        /// Free: fits the padding after `wrapped`.
        var mark: LineMark = .none
    }

    private struct Batch: Sendable {
        var arena: ContiguousArray<Cell> = []
        var rows: ContiguousArray<RowSpan> = []
    }

    /// Oldest first; small enough (`limit / batchSize`) to be a plain FIFO.
    private var batches: ContiguousArray<Batch> = []

    /// Rows already evicted from the oldest (`batches.first`) batch.
    private var headSkip = 0

    public private(set) var count = 0

    /// Every line ever pushed, never decremented — what anchors track.
    /// `count` stops at `limit`, so a full ring shows no growth while rows
    /// are still being evicted.
    public private(set) var totalPushed = 0

    public init(limit: Int = defaultLimit) {
        self.limit = max(0, limit)
        self.batchSize = self.limit == 0 ? 1 : max(1, min(256, self.limit))
    }

    /// Empty, but counting on from `alreadyPushed`: a reflow rebuilds the
    /// rows, and `totalPushed` must not run backwards under anchors.
    init(limit: Int, alreadyPushed: Int) {
        self.init(limit: limit)
        totalPushed = alreadyPushed
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == limit }

    /// `self[index].wrapped` without copying the row's cells out.
    public func isWrapped(at index: Int) -> Bool {
        guard index >= 0, index < count else { return false }
        let global = index + headSkip
        let batchIndex = global / batchSize
        let rowIndex = global % batchSize
        guard batchIndex < batches.count, rowIndex < batches[batchIndex].rows.count else { return false }
        return batches[batchIndex].rows[rowIndex].wrapped
    }

    /// History cells are immutable, but command status may update a mark.
    /// The renderer checks this metadata without copying an arena row out.
    public func mark(at index: Int) -> LineMark {
        guard index >= 0, index < count else { return .none }
        let global = index + headSkip
        let batchIndex = global / batchSize, rowIndex = global % batchSize
        guard batchIndex < batches.count, rowIndex < batches[batchIndex].rows.count else { return .none }
        return batches[batchIndex].rows[rowIndex].mark
    }

    /// Oldest first: index 0 is the line furthest back in history.
    public subscript(index: Int) -> Line {
        guard index >= 0, index < count else { return Line() }
        let global = index + headSkip
        let batchIndex = global / batchSize
        let rowIndex = global % batchSize
        guard batchIndex < batches.count, rowIndex < batches[batchIndex].rows.count else { return Line() }
        let batch = batches[batchIndex]
        let span = batch.rows[rowIndex]
        let start = Int(span.start)
        let end = start + Int(span.length)
        return Line(wrapped: span.wrapped, mark: span.mark, cells: batch.arena[start..<end])
    }

    /// A command's status arrives after its prompt row may have scrolled
    /// into history. An evicted row is not an error.
    public mutating func setMark(_ mark: LineMark, at index: Int) {
        guard index >= 0, index < count else { return }
        let global = index + headSkip
        let batchIndex = global / batchSize
        let rowIndex = global % batchSize
        guard batchIndex < batches.count, rowIndex < batches[batchIndex].rows.count else { return }
        batches[batchIndex].rows[rowIndex].mark = mark
    }

    /// Allocates; for dumps, not the render path.
    public var lines: [Line] {
        (0..<count).map { self[$0] }
    }

    public mutating func push(_ line: Line) {
        guard limit > 0 else { return }
        let length = line.trimmedCount

        if batches.isEmpty || batches[batches.count - 1].rows.count >= batchSize {
            var batch = Batch()
            batch.arena.reserveCapacity(batches.last?.arena.count ?? 0)
            batch.rows.reserveCapacity(batchSize)
            batches.append(batch)
        }
        let tailIndex = batches.count - 1
        let start = Int32(batches[tailIndex].arena.count)
        batches[tailIndex].arena.append(contentsOf: line.cells[..<length])
        batches[tailIndex].rows.append(
            RowSpan(
                start: start, length: Int32(length), wrapped: line.wrapped, mark: line.mark))

        totalPushed += 1
        if count < limit {
            count += 1
        } else {
            headSkip += 1
            if headSkip >= batches[0].rows.count {
                batches.removeFirst()
                headSkip = 0
            }
        }
    }

    /// For tests: the FIFO must stay bounded.
    var batchCount: Int { batches.count }

    public mutating func removeAll() {
        batches.removeAll(keepingCapacity: true)
        headSkip = 0
        count = 0
    }
}
