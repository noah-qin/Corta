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

/// How many bytes the reader feeds under one acquisition of the session lock.
///
/// A byte count alone does not bound the time: a few bytes can erase a whole
/// screen under a background colour, and a 16 KiB slice of that held the lock
/// for 57 ms at 120 × 400 (`PERFORMANCE.md` §5.30). Each slice's time under
/// the lock steers the next one's size: past `shrinkAbove` it halves, to no
/// less than `floor`; under `growBelow` it doubles, to no more than the
/// ceiling, but only after a slice that took the whole limit: the short
/// remainder at a batch's end says nothing about the next full slice, and
/// growing on it let a slow stream's slices swing back past 8 ms. Ordinary
/// output stays at the ceiling, where a slice takes tens of microseconds.
/// Owned by the reader thread alone; it carries over from one batch to the
/// next, since a flood is mostly one-slice batches.
struct FeedSliceSizer {
    static let floor = 256
    static let shrinkAbove: UInt64 = 4_000_000
    static let growBelow: UInt64 = 1_000_000

    let ceiling: Int
    private(set) var limit: Int

    init(ceiling: Int) {
        self.ceiling = max(Self.floor, ceiling)
        limit = self.ceiling
    }

    /// The time the last slice held the lock, in nanoseconds, and how many
    /// bytes it fed.
    mutating func record(heldNanoseconds: UInt64, bytes: Int) {
        if heldNanoseconds > Self.shrinkAbove {
            limit = max(Self.floor, limit / 2)
        } else if heldNanoseconds < Self.growBelow, bytes >= limit {
            limit = min(ceiling, limit * 2)
        }
    }
}
