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

// MARK: - Compression

extension Scrollback {
    /// A stable immutable arena taken under the session lock. Encoding is
    /// outside it; installation checks the namespace and batch identity.
    public struct CompressionWork: Sendable {
        let id: Int
        let namespace: UUID
        let cells: ContiguousArray<Cell>
        let rows: ContiguousArray<RowSpan>
        public func compress() -> CompressionResult {
            let rawCount = cells.count * MemoryLayout<Cell>.stride
            // Kept only under half the raw size, so the encoder gets no more
            // room than that: past it LZ4 returns 0, the same refusal, and
            // nothing is zero-filled or copied twice.
            let capacity = max(0, rawCount / 2 - 1)
            // Encoded into pages outside malloc and copied out at its real size:
            // a 245 KiB `malloc` block per batch, freed a moment later, left
            // holes among the live small blocks that stayed resident (#526). The
            // mapping is only touched where the encoder writes, about 3 to 30 KiB.
            var bytes = ContiguousArray<UInt8>()
            if capacity > 0 {
                bytes = EncodeScratch.with(capacity: capacity) { scratch in
                    let written = cells.withUnsafeBytes { src -> Int in
                        guard let base = src.baseAddress, !src.isEmpty else { return 0 }
                        return compression_encode_buffer(
                            scratch.assumingMemoryBound(to: UInt8.self), capacity,
                            base.assumingMemoryBound(to: UInt8.self), src.count, nil, COMPRESSION_LZ4)
                    }
                    return ContiguousArray(
                        UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: UInt8.self), count: written))
                }
            }
            var rowHyperlinks: [Int: Set<HyperlinkID>] = [:], rowGraphemes: [Int: Set<GraphemeID>] = [:]
            var rowUnderlineColors: [Int: Set<UInt16>] = [:]
            if !bytes.isEmpty {
                for (index, row) in rows.enumerated() {
                    var links: Set<HyperlinkID> = [], clusters: Set<GraphemeID> = []
                    var underlineColors: Set<UInt16> = []
                    for cell in cells[Int(row.start)..<(Int(row.start) + Int(row.length))] {
                        if !cell.hyperlink.isNone { links.insert(cell.hyperlink) }
                        if !cell.grapheme.isNone { clusters.insert(cell.grapheme) }
                        if cell.underlineColorID != 0 { underlineColors.insert(cell.underlineColorID) }
                    }
                    if !links.isEmpty { rowHyperlinks[index] = links }
                    if !clusters.isEmpty { rowGraphemes[index] = clusters }
                    if !underlineColors.isEmpty { rowUnderlineColors[index] = underlineColors }
                }
            }
            return CompressionResult(id: id, namespace: namespace, bytes: bytes, cellCount: cells.count,
                rowHyperlinks: rowHyperlinks, rowGraphemes: rowGraphemes, rowUnderlineColors: rowUnderlineColors)
        }
    }
    public struct CompressionResult: Sendable {
        let id: Int
        let namespace: UUID
        let bytes: ContiguousArray<UInt8>
        let cellCount: Int
        let rowHyperlinks: [Int: Set<HyperlinkID>]
        let rowGraphemes: [Int: Set<GraphemeID>]
        let rowUnderlineColors: [Int: Set<UInt16>]
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
        if !result.bytes.isEmpty, let block = pack(result.bytes) {
            batches[index].compressed = (block, result.cellCount)
            batches[index].arena = []
            batches[index].rowHyperlinks = result.rowHyperlinks
            batches[index].rowGraphemes = result.rowGraphemes
            batches[index].rowUnderlineColors = result.rowUnderlineColors
        }
        return true
    }
    /// Copies compressed bytes into the open chunk, opening the next when
    /// they do not fit.
    private mutating func pack(_ bytes: ContiguousArray<UInt8>) -> CompressedBlock? {
        bytes.withUnsafeBufferPointer { buffer in
            if let block = openChunk?.append(buffer) { return block }
            let chunk = CompressedChunk()
            openChunk = chunk
            return chunk.append(buffer)
        }
    }

    public mutating func compressColdBatches() {
        while let work = nextCompressionWork() { _ = installCompression(work.compress()) }
    }
    /// Representation bytes only; excludes allocator slack, indexes and cache.
    public var storedCellBytes: Int {
        batches.reduce(0) { $0 + ($1.compressed?.block.count ?? ($1.arena.count * MemoryLayout<Cell>.stride)) }
    }
    public var retainedCellCapacityBytes: Int {
        var chunks = Set<ObjectIdentifier>()
        var total = 0
        for batch in batches {
            if let block = batch.compressed?.block {
                if chunks.insert(ObjectIdentifier(block.chunk)).inserted { total += CompressedChunk.capacity }
            } else {
                total += batch.arena.capacity * MemoryLayout<Cell>.stride
            }
        }
        return total
    }
    public func withCellBatches(_ body: (UnsafeBufferPointer<Cell>) -> Void) {
        for batch in batches { arena(batch).withUnsafeBufferPointer(body) }
    }
    public var compressedBatchCount: Int { batches.filter { $0.compressed != nil }.count }
}
