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

import Compression
import Foundation
import Synchronization

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

    fileprivate struct RowSpan: Sendable {
        var start: Int32
        var length: Int32
        var wrapped: Bool
        /// Free: fits the padding after `wrapped`.
        var mark: LineMark = .none
    }

    private struct Batch: Sendable {
        var id: Int
        var arena: ContiguousArray<Cell> = []
        var compressed: (bytes: ContiguousArray<UInt8>, cellCount: Int)?
        var rows: ContiguousArray<RowSpan> = []
        var attempted = false
        var rowHyperlinks: [Int: Set<HyperlinkID>] = [:]
        var rowGraphemes: [Int: Set<GraphemeID>] = [:]
    }

    fileprivate struct ASCIIPlane: Sendable {
        var bytes: ContiguousArray<UInt8>
        var nonASCII: [[UInt32]]
        var unsupported: [Bool]
        var byteCost: Int {
            bytes.count + unsupported.count + nonASCII.count * MemoryLayout<[UInt32]>.stride
                + nonASCII.reduce(0) { $0 + $1.count * MemoryLayout<UInt32>.stride }
        }
    }

    struct ASCIIReader {
        fileprivate var id = -1
        fileprivate var plane: ASCIIPlane?
    }

    /// Shared only for immutable decoded arenas. Count AND byte limits keep
    /// very wide histories from turning a four-batch cache into a large one.
    private final class Cache: Sendable {
        struct State: Sendable {
            var valid = true
            var entries: [(id: Int, cells: ContiguousArray<Cell>)] = []
            var entryBytes = 0
            var planes: [Int: ASCIIPlane] = [:]
            var planeOrder: [Int] = []
            var planeBytes = 0
        }
        static let entryLimit = 4
        static let cellByteLimit = 8 << 20
        static let planeByteLimit = 32 << 20
        let identity = UUID()
        let state = Mutex(State())
        func cells(id: Int, decode: () -> ContiguousArray<Cell>) -> ContiguousArray<Cell> {
            if let hit = state.withLock({ s -> ContiguousArray<Cell>? in
                guard let index = s.entries.firstIndex(where: { $0.id == id }) else { return nil }
                let entry = s.entries.remove(at: index)
                s.entries.append(entry)
                return entry.cells
            }) { return hit }
            // Decode outside the cache lock; racing immutable misses are safe.
            let cells = decode()
            state.withLock { s in
                let bytes = cells.count * MemoryLayout<Cell>.stride
                guard s.valid, bytes <= Self.cellByteLimit else { return }
                if s.entries.contains(where: { $0.id == id }) { return }
                s.entries.append((id, cells))
                s.entryBytes += bytes
                while s.entries.count > Self.entryLimit || s.entryBytes > Self.cellByteLimit {
                    s.entryBytes -= s.entries.removeFirst().cells.count * MemoryLayout<Cell>.stride
                }
            }
            return cells
        }
        func plane(id: Int, build: () -> ASCIIPlane) -> ASCIIPlane {
            if let hit = state.withLock({ $0.planes[id] }) { return hit }
            let plane = build()
            state.withLock { s in
                guard s.valid, s.planes[id] == nil else { return }
                s.planes[id] = plane; s.planeOrder.append(id); s.planeBytes += plane.byteCost
                while s.planeBytes > Self.planeByteLimit {
                    let id = s.planeOrder.removeFirst()
                    if let removed = s.planes.removeValue(forKey: id) { s.planeBytes -= removed.byteCost }
                }
            }
            return plane
        }
        func remove(id: Int) {
            state.withLock { s in
                s.entries.removeAll { $0.id == id }
                if let removed = s.planes.removeValue(forKey: id) { s.planeBytes -= removed.byteCost }
                s.planeOrder.removeAll { $0 == id }
            }
        }
        func invalidate() { state.withLock { $0.valid = false; $0.entries.removeAll(); $0.planes.removeAll(); $0.planeOrder.removeAll(); $0.planeBytes = 0 } }
    }
    private var cache = Cache()
    /// First batch not yet attempted; each sealed batch is visited once.
    private var compressionCursor = 0

    /// A stable immutable arena taken under the session lock. Encoding is
    /// outside it; installation checks the namespace and batch identity.
    public struct CompressionWork: Sendable {
        fileprivate let id: Int
        fileprivate let namespace: UUID
        fileprivate let cells: ContiguousArray<Cell>
        fileprivate let rows: ContiguousArray<RowSpan>
        public func compress() -> CompressionResult {
            let rawCount = cells.count * MemoryLayout<Cell>.stride
            // Kept only under half the raw size, so the encoder gets no more
            // room than that: past it LZ4 returns 0, the same refusal, and
            // nothing is zero-filled or copied twice.
            let capacity = max(0, rawCount / 2 - 1)
            let bytes = ContiguousArray<UInt8>(unsafeUninitializedCapacity: capacity) { dst, initialized in
                initialized = cells.withUnsafeBytes { src in
                    guard let base = src.baseAddress, !src.isEmpty, let out = dst.baseAddress else { return 0 }
                    return compression_encode_buffer(out, dst.count,
                        base.assumingMemoryBound(to: UInt8.self), src.count, nil, COMPRESSION_LZ4)
                }
            }
            var rowHyperlinks: [Int: Set<HyperlinkID>] = [:], rowGraphemes: [Int: Set<GraphemeID>] = [:]
            if !bytes.isEmpty {
                for (index, row) in rows.enumerated() {
                    var links: Set<HyperlinkID> = [], clusters: Set<GraphemeID> = []
                    for cell in cells[Int(row.start)..<(Int(row.start) + Int(row.length))] {
                        if !cell.hyperlink.isNone { links.insert(cell.hyperlink) }
                        if !cell.grapheme.isNone { clusters.insert(cell.grapheme) }
                    }
                    if !links.isEmpty { rowHyperlinks[index] = links }
                    if !clusters.isEmpty { rowGraphemes[index] = clusters }
                }
            }
            return CompressionResult(id: id, namespace: namespace, bytes: bytes, cellCount: cells.count,
                rowHyperlinks: rowHyperlinks, rowGraphemes: rowGraphemes)
        }
    }
    public struct CompressionResult: Sendable {
        fileprivate let id: Int
        fileprivate let namespace: UUID
        fileprivate let bytes: ContiguousArray<UInt8>
        fileprivate let cellCount: Int
        fileprivate let rowHyperlinks: [Int: Set<HyperlinkID>]
        fileprivate let rowGraphemes: [Int: Set<GraphemeID>]
    }

    /// Four sealed batches plus the mutable tail remain hot.
    static let hotBatchCount = 5

    /// An integer compare, for asking under the session lock whether a
    /// compression pass is owed at all.
    var hasCompressionWork: Bool { compressionCursor < batches.count - Self.hotBatchCount }

    public func nextCompressionWork() -> CompressionWork? {
        guard hasCompressionWork else { return nil }
        let batch = batches[compressionCursor]
        return CompressionWork(id: batch.id, namespace: cache.identity, cells: batch.arena, rows: batch.rows)
    }

    @discardableResult
    public mutating func installCompression(_ result: CompressionResult) -> Bool {
        guard result.namespace == cache.identity,
              let index = batches.firstIndex(where: { $0.id == result.id }),
              index < batches.count - Self.hotBatchCount, !batches[index].attempted,
              batches[index].compressed == nil else { return false }
        batches[index].attempted = true
        while compressionCursor < batches.count, batches[compressionCursor].attempted {
            compressionCursor += 1
        }
        if !result.bytes.isEmpty {
            batches[index].compressed = (result.bytes, result.cellCount)
            batches[index].arena = []
            batches[index].rowHyperlinks = result.rowHyperlinks
            batches[index].rowGraphemes = result.rowGraphemes
        }
        return true
    }
    public mutating func compressColdBatches() {
        while let work = nextCompressionWork() { _ = installCompression(work.compress()) }
    }
    /// Representation bytes only; excludes allocator slack, indexes and cache.
    public var storedCellBytes: Int {
        batches.reduce(0) { $0 + ($1.compressed?.bytes.count ?? ($1.arena.count * MemoryLayout<Cell>.stride)) }
    }
    public var retainedCellCapacityBytes: Int {
        batches.reduce(0) { $0 + ($1.compressed?.bytes.capacity ?? ($1.arena.capacity * MemoryLayout<Cell>.stride)) }
    }
    public func withCellBatches(_ body: (UnsafeBufferPointer<Cell>) -> Void) {
        for batch in batches { arena(batch).withUnsafeBufferPointer(body) }
    }
    public var compressedBatchCount: Int { batches.filter { $0.compressed != nil }.count }
    /// `cached: false` for a one-pass sweep (reflow), which would only push
    /// the hot batches out of the shared cache.
    private func arena(_ batch: Batch, cached: Bool = true) -> ContiguousArray<Cell> {
        guard let compressed = batch.compressed else { return batch.arena }
        let decode = {
            var cells = ContiguousArray<Cell>(repeating: .blank, count: compressed.cellCount)
            let decoded = cells.withUnsafeMutableBytes { dst in compressed.bytes.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dst.count, src.baseAddress!, src.count, nil, COMPRESSION_LZ4)
            } }
            precondition(decoded == compressed.cellCount * MemoryLayout<Cell>.stride, "invalid internal scrollback block")
            return cells
        }
        return cached ? cache.cells(id: batch.id, decode: decode) : decode()
    }

    /// One byte per stored cell, with distinct Unicode/spacer sentinels.
    /// Row metadata preserves Unicode fallback and original column positions.
    func appendASCIIRow(at index: Int, documentRow: Int,
                        text: inout ContiguousArray<UInt8>, rows: inout ContiguousArray<Int32>,
                        columns: inout ContiguousArray<Int32>, reader: inout ASCIIReader, nonASCIIIsOpaque: (UInt32) -> Bool) -> Bool {
        guard index >= 0, index < count else { return false }
        let global = index + headSkip, batch = batches[global / batchSize]
        let rowIndex = global % batchSize
        let build = { () -> ASCIIPlane in
            let cells = arena(batch)
            var bytes = ContiguousArray<UInt8>(repeating: 0x80, count: cells.count)
            var nonASCII = [[UInt32]](repeating: [], count: batch.rows.count)
            var unsupported = [Bool](repeating: false, count: batch.rows.count)
            // Borrow once: the plane and immutable arena cannot resize in
            // this scope, so per-cell COW/exclusivity checks are unnecessary.
            bytes.withUnsafeMutableBufferPointer { output in
                cells.withUnsafeBufferPointer { source in
                    for (r, span) in batch.rows.enumerated() {
                        for offset in Int(span.start)..<(Int(span.start) + Int(span.length)) {
                            let cell = source[offset]
                            if cell.attributes.contains(.wideSpacer) { output[offset] = 0x81; continue }
                            if !cell.grapheme.isNone { unsupported[r] = true }
                            if cell.scalar < 0x80 { output[offset] = UInt8(cell.scalar) }
                            else if !nonASCII[r].contains(cell.scalar) { nonASCII[r].append(cell.scalar) }
                        }
                    }
                }
            }
            return ASCIIPlane(bytes: bytes, nonASCII: nonASCII, unsupported: unsupported)
        }
        let plane: ASCIIPlane
        if reader.id == batch.id, let cached = reader.plane { plane = cached }
        else {
            plane = global / batchSize == batches.count - 1 ? build() : cache.plane(id: batch.id, build: build)
            reader.id = batch.id; reader.plane = plane
        }
        guard !plane.unsupported[rowIndex], plane.nonASCII[rowIndex].allSatisfy(nonASCIIIsOpaque) else { return false }
        let span = batch.rows[rowIndex]
        for column in 0..<Int(span.length) {
            let byte = plane.bytes[Int(span.start) + column]
            if byte == 0x81 { continue }
            text.append(byte); rows.append(Int32(documentRow)); columns.append(Int32(column))
        }
        return true
    }

    func liveHyperlinkIDs() -> Set<HyperlinkID> {
        liveIDs(rows: \.rowHyperlinks) { $0.hyperlink.isNone ? nil : $0.hyperlink }
    }
    func liveGraphemeIDs() -> Set<GraphemeID> {
        liveIDs(rows: \.rowGraphemes) { $0.grapheme.isNone ? nil : $0.grapheme }
    }

    /// Ids still referenced by retained rows: scanned in an arena, read
    /// from the per-row index a compressed batch kept, skipping evicted rows.
    private func liveIDs<ID: Hashable>(
        rows perRow: KeyPath<Batch, [Int: Set<ID>]>, cell id: (Cell) -> ID?
    ) -> Set<ID> {
        var ids: Set<ID> = []
        for (index, batch) in batches.enumerated() {
            let first = index == 0 ? headSkip : 0
            if batch.compressed == nil {
                for row in batch.rows.dropFirst(first) {
                    for cell in batch.arena[Int(row.start)..<(Int(row.start) + Int(row.length))] {
                        if let live = id(cell) { ids.insert(live) }
                    }
                }
            } else {
                for (row, live) in batch[keyPath: perRow] where row >= first { ids.formUnion(live) }
            }
        }
        return ids
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

    struct LineReader {
        fileprivate var id = -1
        fileprivate var cells: ContiguousArray<Cell> = []
    }
    func appendCells(at index: Int, reader: inout LineReader, into cells: inout [Cell]) -> (wrapped: Bool, mark: LineMark) {
        let global = index + headSkip, batch = batches[global / batchSize]
        if reader.id != batch.id { reader.cells = arena(batch, cached: false); reader.id = batch.id }
        let span = batch.rows[global % batchSize]
        cells.append(contentsOf: reader.cells[Int(span.start)..<(Int(span.start) + Int(span.length))])
        return (span.wrapped, span.mark)
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
        return Line(wrapped: span.wrapped, mark: span.mark, cells: arena(batch)[start..<end])
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
            var batch = Batch(id: totalPushed)
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
                cache.remove(id: batches[0].id)
                batches.removeFirst()
                compressionCursor = max(0, compressionCursor - 1)
                headSkip = 0
            }
        }
    }

    /// For tests: the FIFO must stay bounded.
    var batchCount: Int { batches.count }

    public mutating func removeAll() {
        cache.invalidate()
        cache = Cache()
        batches.removeAll(keepingCapacity: true)
        compressionCursor = 0
        headSkip = 0
        count = 0
    }
}
