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

/// Process-wide exclusive claims on transfer destinations.
///
/// Two transfers to one destination used to share its `.corta-part`: the
/// second truncated and committed it while the first still held an open
/// handle to the same file, so the first kept writing into a destination
/// the second had already reported done. Every engine in the process asks
/// here before it touches a destination, so a second transfer to the same
/// path waits for the first to finish — whichever browser window, folder
/// transfer or remote-edit save it came from — and transfers to different
/// paths still run side by side.
///
/// A claim is a key, not a path: the engine builds it from its
/// `destinationScope` (the host, for remote paths) and a lexically
/// normalised path. Another process gets no claim from here; the engine's
/// exclusive partial creation is what keeps it from writing into ours.
final class SFTPDestinationLocks: @unchecked Sendable {
    static let shared = SFTPDestinationLocks()

    private struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var held: Set<String> = []
        var waiters: [String: [Waiter]] = [:]
        var nextToken: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Waits, FIFO and cancellably, until `key` is free, then holds it.
    /// Throws `.cancelled` when the caller is cancelled first.
    func acquire(_ key: String) async throws(SFTPError) {
        if Task.isCancelled { throw .cancelled }
        let token = state.withLock { state -> UInt64? in
            if state.held.insert(key).inserted { return nil }
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        guard let token else { return }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let outcome = state.withLock { state -> Bool? in
                    guard !Task.isCancelled else { return false }
                    if state.held.insert(key).inserted { return true }
                    state.waiters[key, default: []].append(
                        Waiter(token: token, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard var list = state.waiters[key],
                    let index = list.firstIndex(where: { $0.token == token })
                else { return nil }
                let waiter = list.remove(at: index)
                state.waiters[key] = list.isEmpty ? nil : list
                return waiter.continuation
            }
            cancelled?.resume(returning: false)
        }
        guard admitted else { throw .cancelled }
    }

    /// Hands the claim to the next waiter, or frees it.
    func release(_ key: String) {
        let next = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            if var list = state.waiters[key], !list.isEmpty {
                // The claim passes straight to the waiter; `held` keeps the key.
                let waiter = list.removeFirst()
                state.waiters[key] = list.isEmpty ? nil : list
                return waiter.continuation
            }
            state.held.remove(key)
            return nil
        }
        next?.resume(returning: true)
    }

    /// Whether anything holds `key` — for tests.
    func isHeld(_ key: String) -> Bool {
        state.withLock { $0.held.contains(key) }
    }

    /// `path` with empty and `.` components dropped and `..` applied
    /// lexically, so `/a//b/./c` and `/a/b/c` claim the same destination.
    static func normalizedRemotePath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == "..", let last = components.last, last != ".." {
                components.removeLast()
                continue
            }
            components.append(component)
        }
        let joined = components.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }

    /// A local destination's key: standardised, and case-folded because the
    /// default macOS volume is case-insensitive — over-serialising two
    /// names that differ only in case costs a wait, never a file.
    static func normalizedLocalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }
}
