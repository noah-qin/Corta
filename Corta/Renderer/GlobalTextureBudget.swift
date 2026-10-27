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

import CortaTerminal
import Synchronization

/// The app-wide image texture budget: VRAM is shared, and per-pane caps
/// don't stop N panes exhausting it. Texture leases release reservations
/// only when the last texture owner disappears, including GPU retention.
nonisolated final class GlobalTextureBudget: Sendable {
    static let shared = GlobalTextureBudget(limit: KittyGraphics.maximumGlobalTextureBytes)

    let limit: Int

    private struct State {
        var reserved = 0
        var retired = 0
        var releaseCount = 0
    }

    private let state = Mutex(State())

    /// Bumped on every release, so a renderer that skipped an image learns
    /// cheaply that space may exist.
    var generation: Int { state.withLock { $0.releaseCount } }

    var reservedBytes: Int { state.withLock { $0.reserved } }

    var retiredBytes: Int { state.withLock { $0.retired } }

    func markRetired(_ bytes: Int) {
        state.withLock { $0.retired += bytes }
    }

    init(limit: Int) {
        self.limit = limit
    }

    func tryReserve(_ bytes: Int) -> Bool {
        state.withLock { state in
            guard bytes <= limit - state.reserved else { return false }
            state.reserved += bytes
            return true
        }
    }

    func release(_ bytes: Int, retired wasRetired: Bool = false) {
        state.withLock { state in
            state.reserved -= bytes
            if wasRetired { state.retired -= bytes }
            state.releaseCount &+= 1
        }
    }
}
