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

import CortaSFTP
import Foundation

/// The local file questions a transfer asks before it starts. A transfer's
/// source or destination can be on a network volume whose server has gone,
/// where `stat` blocks for minutes: asked on the main actor, that is the whole
/// app frozen, and the window unable to close.
///
/// Each question runs under `PathProbe.answer` — on a thread of its own, timed
/// and under a budget — one at a time per queue, so dropping a thousand files
/// asks a thousand questions in turn rather than spending the budget at once.
/// One that does not answer in time is nil: that row fails, and can be retried.
@MainActor
final class SFTPLocalChecks {
    /// Generous for a disk, and for a Keep Both search through 2,000 names;
    /// short enough to say something about a mount that has gone.
    nonisolated static let timeout: DispatchTimeInterval = .seconds(5)
    /// Checks still blocked, per queue. Each holds a thread until its mount
    /// answers; past this a check is nil at once, without one. Its own, not
    /// shared: with one check at a time, only a hung one can ever be counted
    /// here, so a full budget means a mount and never a busy moment elsewhere.
    nonisolated static let maximumOutstanding = 8

    private let timeout: DispatchTimeInterval
    private let budget: PathProbe.Budget
    /// Runs on the check's thread first; a test holds it there as a mount would.
    private let beforeCheck: @Sendable () -> Void
    private var tail: Task<Void, Never>?

    enum Failure: Error, Equatable {
        case timedOut, budgetExhausted, cancelled
    }

    init(
        timeout: DispatchTimeInterval = SFTPLocalChecks.timeout,
        budget: PathProbe.Budget = PathProbe.Budget(limit: SFTPLocalChecks.maximumOutstanding),
        beforeCheck: @escaping @Sendable () -> Void = {}
    ) {
        self.timeout = timeout
        self.budget = budget
        self.beforeCheck = beforeCheck
    }

    /// `body`'s answer, or nil when it was late, there was no room for it, or
    /// the caller was cancelled before its turn.
    func answer<Answer: Sendable>(_ body: @escaping @Sendable () -> Answer) async -> Result<Answer, Failure> {
        let previous = tail
        let timeout = timeout, budget = budget, beforeCheck = beforeCheck
        let work = Task<Result<Answer, Failure>, Never> {
            await previous?.value
            guard !Task.isCancelled else { return .failure(.cancelled) }
            // `answer` waits for its thread, so it waits on one too: this is
            // neither the main actor nor the cooperative pool.
            return await withCheckedContinuation { continuation in
                PathProbe.run {
                    var failure = Failure.timedOut
                    let value = PathProbe.answer(timeout: timeout, budget: budget, onBudgetExhausted: {
                        failure = .budgetExhausted
                    }) {
                        beforeCheck()
                        return body()
                    }
                    continuation.resume(returning: value.map(Result.success) ?? .failure(failure))
                }
            }
        }
        tail = Task { _ = await work.value }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

/// What the checks read. `nonisolated`, and plain values: they run on probe
/// threads and come back to the queue.
nonisolated enum SFTPLocalFacts {
    struct Attributes: Sendable {
        var exists = false
        var size: UInt64?
        var modified: Date?
    }

    /// An upload's source. A chosen folder is a directory transfer — the whole
    /// tree, one atomic file at a time, symbolic links skipped and reported
    /// (`SFTPTransferEngine.uploadDirectory`) — and a link to one is not.
    struct Source: Sendable {
        var isDirectory = false
        var attributes = Attributes()
    }

    static func attributes(atPath path: String) -> Attributes {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path) else {
            return Attributes()
        }
        return Attributes(
            exists: true, size: (values[.size] as? NSNumber)?.uint64Value,
            modified: values[.modificationDate] as? Date)
    }

    static func source(_ url: URL) -> Source {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return Source(
            isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true,
            attributes: attributes(atPath: url.path))
    }

    /// A download's destination and the partial an interrupted one left.
    static func destination(atPath path: String) -> (destination: Attributes, partial: Attributes) {
        (attributes(atPath: path), attributes(atPath: SFTPTransferEngine.partialPath(for: path)))
    }

    static func isFree(_ path: String) -> Bool {
        !FileManager.default.fileExists(atPath: path)
            && !FileManager.default.fileExists(atPath: SFTPTransferEngine.partialPath(for: path))
    }

    /// The first Keep Both name neither a file nor a partial has, or nil.
    static func firstFreeCandidate(for path: String, attempts: Int) -> String? {
        for attempt in 1...attempts {
            let candidate = SFTPBrowserModel.keepBothCandidate(path, attempt: attempt)
            if isFree(candidate) { return candidate }
        }
        return nil
    }
}
