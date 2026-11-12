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
import Synchronization

/// Where compressed history lives: a few large blocks, not one small
/// allocation per batch.
///
/// A compressed batch is 3 to 30 KiB depending on the text, and history
/// replaces old batches with new ones of a different size as the workload
/// changes (a log, then CJK, then colour codes). libmalloc serves that size
/// range from its small zone, where a freed 3 KiB hole cannot hold a 28 KiB
/// buffer, so after a flood the zone held about 47 MB free beside 13 MB live
/// and `malloc_zone_pressure_relief` returned none of it (#526). Batches leave
/// history oldest first, so packing them in arrival order into one-megabyte
/// chunks makes a chunk free whole, to the system, once its last batch is gone.
final class CompressedChunk: @unchecked Sendable {
    /// One megabyte holds 37 batches of the densest text measured and several
    /// hundred of a plain log; a batch is at most half a batch's raw size,
    /// 245 KiB, so it always fits an empty chunk.
    static let capacity = 1 << 20

    private let storage: UnsafeMutableRawPointer
    /// Bytes handed out. Shared by every copy of a `Scrollback` that holds this
    /// chunk, so two copies (a suspended main screen and the live one) can never
    /// be given the same range.
    private let used = Mutex(0)

    /// Its own mapping, not a `malloc` block: a megabyte from `malloc` came out of
    /// the same zone as the small blocks beside it, and the holes its neighbours
    /// left stayed resident. Unmapping gives every page back at once.
    init() {
        storage = VirtualMemory.map(Self.capacity)
    }

    deinit { VirtualMemory.unmap(storage, Self.capacity) }

    /// Copies `bytes` in and names the range, or nil when it does not fit.
    func append(_ bytes: UnsafeBufferPointer<UInt8>) -> CompressedBlock? {
        guard let base = bytes.baseAddress, !bytes.isEmpty, bytes.count <= Self.capacity else { return nil }
        let offset: Int? = used.withLock { used in
            let start = (used + 15) & ~15
            guard start + bytes.count <= Self.capacity else { return nil }
            used = start + bytes.count
            return start
        }
        guard let offset else { return nil }
        (storage + offset).copyMemory(from: base, byteCount: bytes.count)
        return CompressedBlock(chunk: self, offset: offset, count: bytes.count)
    }

    fileprivate func pointer(at offset: Int) -> UnsafeRawPointer { UnsafeRawPointer(storage + offset) }
}

/// A range of a `CompressedChunk`, written once before it is shared and never
/// changed, which is why reading it from another thread needs no lock.
struct CompressedBlock: Sendable {
    let chunk: CompressedChunk
    let offset: Int
    let count: Int

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: chunk.pointer(at: offset), count: count))
    }
}

/// Anonymous pages straight from the kernel, for blocks big enough that
/// `malloc` would place them among small, long-lived neighbours.
enum VirtualMemory {
    static func map(_ byteCount: Int) -> UnsafeMutableRawPointer {
        let address = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let address, address != MAP_FAILED else {
            // Out of address space: the process cannot go on anyway, as when `malloc` fails.
            fatalError("cannot map \(byteCount) bytes")
        }
        return address
    }

    static func unmap(_ pointer: UnsafeMutableRawPointer, _ byteCount: Int) {
        munmap(pointer, byteCount)
    }
}

/// The encoder's output space, reused. Mapping fresh pages for every batch cost
/// a zero-fill fault and an unmap each time: about ten times the system time of
/// a scrolling flood (#526 follow-up). A few mappings are kept, each only as
/// resident as the most the encoder ever wrote into it, and handed to one
/// encoder at a time.
enum EncodeScratch {
    /// A mapping owned by whoever took it from the pool; only one holder at a time.
    private struct Mapping: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let capacity: Int
    }

    private static let pool = Mutex<[Mapping]>([])
    private static let pooled = 4

    static func with<R>(capacity: Int, _ body: (UnsafeMutableRawPointer) -> R) -> R {
        let taken: Mapping? = pool.withLock { pool in
            guard let index = pool.firstIndex(where: { $0.capacity >= capacity }) else { return nil }
            return pool.remove(at: index)
        }
        let scratch = taken ?? Mapping(pointer: VirtualMemory.map(capacity), capacity: capacity)
        let result = body(scratch.pointer)
        let kept = pool.withLock { pool -> Bool in
            guard pool.count < pooled else { return false }
            pool.append(scratch)
            return true
        }
        if !kept { VirtualMemory.unmap(scratch.pointer, scratch.capacity) }
        return result
    }
}
