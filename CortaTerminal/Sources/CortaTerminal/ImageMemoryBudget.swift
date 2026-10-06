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

/// Kitty image bytes shared by many terminals — the app makes one and hands
/// it to every session, so N panes of hostile output cannot each fill their
/// own `KittyGraphics.maximumPaneImageBytes`. Not a singleton (D07): the core
/// only knows the instance it was given.
///
/// Each session reports what its terminal retains after every feed slice and
/// is told, before the next, what the others leave it. Two sessions storing at
/// the same instant can each see the same room, so the limit may be exceeded
/// by at most one image per concurrently storing session — a bound, not an
/// exact cap.
public final class ImageMemoryBudget: Sendable {
    public let limit: Int
    private let usage = Mutex<[ObjectIdentifier: Int]>([:])

    public init(limit: Int = KittyGraphics.maximumProcessImageBytes) {
        self.limit = max(0, limit)
    }

    /// Bytes reported by every owner.
    public var totalBytes: Int {
        usage.withLock { $0.values.reduce(0, +) }
    }

    /// What `owner` may retain: the limit less everyone else's report.
    func allowance(for owner: ObjectIdentifier) -> Int {
        usage.withLock { usage in
            let others = usage.reduce(0) { $0 + ($1.key == owner ? 0 : $1.value) }
            return max(0, limit - others)
        }
    }

    func report(_ bytes: Int, for owner: ObjectIdentifier) {
        usage.withLock { $0[owner] = bytes > 0 ? bytes : nil }
    }

    func release(_ owner: ObjectIdentifier) {
        usage.withLock { $0[owner] = nil }
    }
}
