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

import Foundation
import Metal
import ObjectiveC
import Synchronization

/// Budget ownership: texture leases, decode permits, and the association
/// that ties a lease to its texture's lifetime.
nonisolated extension KittyImageRenderer {
    /// One texture's share of the pane and global budgets, returned when
    /// its last owner — the cache, or Metal past eviction — lets go.
    final class TextureLease {
        let bytes: Int
        let pane: GlobalTextureBudget
        let global: GlobalTextureBudget
        private var retired = false
        init(bytes: Int, pane: GlobalTextureBudget, global: GlobalTextureBudget) {
            self.bytes = bytes
            self.pane = pane
            self.global = global
        }
        func retire() {
            guard !retired else { return }
            retired = true
            pane.markRetired(bytes)
            global.markRetired(bytes)
        }
        deinit {
            pane.release(bytes, retired: retired)
            global.release(bytes, retired: retired)
            NotificationCenter.default.post(name: KittyImageRenderer.decodeFinished, object: nil)
        }
    }

    /// Scheduler abandonment and renderer teardown return admission too.
    final class DecodePermit: Sendable {
        private let released = Atomic<Bool>(false)
        func release() {
            guard !released.exchange(true, ordering: .acquiringAndReleasing) else { return }
            KittyImageRenderer.decodeBudget.release(1)
            NotificationCenter.default.post(name: KittyImageRenderer.decodeFinished, object: nil)
        }
        deinit { release() }
    }

    /// A texture is born carrying its lease: MTL4 retains textures past cache
    /// eviction (and a timed-out blit past this call), so whoever holds it
    /// last returns the quota.
    func attach(_ lease: TextureLease, to texture: MTLTexture) {
        objc_setAssociatedObject(
            texture, Unmanaged.passUnretained(Self.textureLeaseKey).toOpaque(), lease,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func lease(of texture: MTLTexture) -> TextureLease? {
        objc_getAssociatedObject(texture, Unmanaged.passUnretained(textureLeaseKey).toOpaque()) as? TextureLease
    }
}
