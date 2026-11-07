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
import Synchronization

/// Queued with the store's writes. The app can also finish a pending clear
/// during its bounded quit flush, when the main actor can't run the waiter.
nonisolated final class HistoryFileDeletion: Sendable {
    private let completion = DispatchGroup()
    private let outcome = Mutex<Result<Void, any Error>?>(nil)

    init(_ url: URL, on queue: DispatchQueue) {
        queue.async(group: completion) { [self] in
            let result = Result { try PrivateFile.removeIfPresent(url) }
            outcome.withLock { $0 = result }
        }
    }

    var result: Result<Void, any Error>? { outcome.withLock { $0 } }

    func wait() async {
        await withCheckedContinuation { continuation in
            completion.notify(queue: .main) { continuation.resume() }
        }
    }

    func wait(until deadline: DispatchTime) {
        _ = completion.wait(timeout: deadline)
    }
}
