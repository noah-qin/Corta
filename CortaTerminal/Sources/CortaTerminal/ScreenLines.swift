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

import Synchronization

/// Positive delta scrolls up, negative down. Sequence numbers belong to a
/// ScreenLines generation; consumers detect a missing event and rebuild.
public struct ScrollEvent: Equatable, Sendable {
    public var top: Int16
    public var bottom: Int16
    public var delta: Int16
}

/// Process-wide: no two `ScreenLines` ever share a generation.
private let nextScreenLinesGeneration = Atomic<UInt64>(0)

/// Screen rows in a circular buffer: a full-screen scroll is one slot reset
/// and an index bump instead of `rows - 1` assignments.
struct ScreenLines: RandomAccessCollection, MutableCollection, Sendable {
    typealias Index = Int
    typealias Element = Line

    private var storage: ContiguousArray<Line>
    private var head = 0

    /// Revisions compare only within a generation: the alternate screen and a
    /// column change swap in a fresh instance whose stamps restart.
    let generation: UInt64

    /// Bumped by the only two ways a `Grid` touches a row (`_modify`, `rotateUp`).
    /// "Unchanged since", not "equal": a false "changed" costs a rebuild, never
    /// a stale row.
    private var revisions: ContiguousArray<UInt64>
    private var nextRevision: UInt64 = 0

    /// The renderer shifts its cache by the delta. Not `totalPushed`, which is
    /// silent on the alternate screen.
    private(set) var totalRotated: UInt64 = 0
    static let scrollEventCapacity = 64
    private var scrollEvents = ContiguousArray<ScrollEvent>()
    private(set) var scrollEventsTotal: UInt64 = 0

    func scrollEvent(at sequence: UInt64) -> ScrollEvent? {
        guard sequence < scrollEventsTotal,
            scrollEventsTotal - sequence <= UInt64(scrollEvents.count) else { return nil }
        return scrollEvents[Int(sequence % UInt64(Self.scrollEventCapacity))]
    }

    private mutating func recordScroll(top: Int, bottom: Int, delta: Int) {
        let event = ScrollEvent(top: Int16(top), bottom: Int16(bottom), delta: Int16(delta))
        let index = Int(scrollEventsTotal % UInt64(Self.scrollEventCapacity))
        if scrollEvents.count < Self.scrollEventCapacity { scrollEvents.append(event) }
        else { scrollEvents[index] = event }
        scrollEventsTotal &+= 1
    }

    init(repeating line: Line, count: Int) {
        storage = ContiguousArray(repeating: line, count: count)
        revisions = ContiguousArray(repeating: 0, count: count)
        generation = nextScreenLinesGeneration.wrappingAdd(1, ordering: .relaxed).newValue
    }

    init(_ lines: ContiguousArray<Line>) {
        storage = lines
        revisions = ContiguousArray(repeating: 0, count: lines.count)
        generation = nextScreenLinesGeneration.wrappingAdd(1, ordering: .relaxed).newValue
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    subscript(position: Int) -> Line {
        get { storage[physicalIndex(position)] }
        set {
            let index = physicalIndex(position)
            storage[index] = newValue
            stamp(index)
        }
        _modify {
            let index = physicalIndex(position)
            yield &storage[index]
            stamp(index)
        }
    }

    func revision(at position: Int) -> UInt64 {
        revisions[physicalIndex(position)]
    }

    @inline(__always)
    private mutating func stamp(_ physicalIndex: Int) {
        nextRevision &+= 1
        revisions[physicalIndex] = nextRevision
    }

    mutating func rotateUp(_ count: Int) {
        guard !storage.isEmpty else { return }
        let clamped = Swift.min(Swift.max(0, count), storage.count)
        for _ in 0..<clamped {
            storage[head].recycle()
            stamp(head)
            head += 1
            if head == storage.count { head = 0 }
        }
        totalRotated &+= UInt64(clamped)
        if clamped > 0 { recordScroll(top: 0, bottom: storage.count - 1, delta: clamped) }
    }

    /// Explicit swaps stamp both logical rows, including when the ring wraps.
    mutating func swapAt(_ i: Int, _ j: Int) {
        guard i != j else { return }
        let a = physicalIndex(i), b = physicalIndex(j)
        storage.swapAt(a, b)
        stamp(a)
        stamp(b)
    }

    /// Rotate storage and revisions together; only exposed rows are stamped.
    /// Three reversals cost O(region height), independent of scroll count.
    mutating func rotate(top: Int, bottom: Int, by delta: Int) {
        let count = Swift.min(abs(delta), bottom - top + 1)
        guard count > 0 else { return }
        func reverse(_ first: Int, _ last: Int) {
            var a = first, b = last
            while a < b {
                let i = physicalIndex(a), j = physicalIndex(b)
                storage.swapAt(i, j)
                revisions.swapAt(i, j)
                a += 1; b -= 1
            }
        }
        let left = delta > 0 ? count : bottom - top + 1 - count
        reverse(top, top + left - 1)
        reverse(top + left, bottom)
        reverse(top, bottom)
        let exposed = delta > 0 ? (bottom - count + 1)...bottom : top...(top + count - 1)
        for row in exposed { self[row].recycle() }
        recordScroll(top: top, bottom: bottom, delta: delta > 0 ? count : -count)
    }

    mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Line {
        materialize()
        let before = storage.count
        storage.append(contentsOf: newElements)
        // Only keeps `revisions` the same length: a resize rebuilds anyway.
        revisions.append(contentsOf: repeatElement(0, count: storage.count - before))
    }

    mutating func removeFirst(_ count: Int) {
        materialize()
        storage.removeFirst(count)
        revisions.removeFirst(count)
    }

    mutating func removeLast(_ count: Int) {
        materialize()
        storage.removeLast(count)
        revisions.removeLast(count)
    }

    private func physicalIndex(_ logical: Int) -> Int {
        precondition(logical >= 0 && logical < storage.count)
        let index = head + logical
        return index < storage.count ? index : index - storage.count
    }

    private mutating func materialize() {
        guard head != 0 else { return }
        let reorderedRevisions = ContiguousArray((0..<storage.count).map { revisions[physicalIndex($0)] })
        storage = ContiguousArray(self)
        revisions = reorderedRevisions
        head = 0
    }
}
