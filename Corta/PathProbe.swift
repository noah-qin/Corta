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

/// `stat` without trusting it to return: on a network mount whose server
/// has gone, it can block for minutes, and on the main thread that is the
/// whole app frozen — at every launch, when the saved arrangement names
/// such a directory. The calls run on their own queue and the caller waits
/// at most `timeout`; a path that has not answered by then counts as
/// absent, and its thread is left to finish whenever the mount does.
nonisolated enum PathProbe {
    /// Checks started and not yet returned, against a cap.
    final class Budget: Sendable {
        let limit: Int
        private let count = Mutex(0)

        init(limit: Int) { self.limit = limit }

        func take() -> Bool {
            count.withLock { count in
                guard count < limit else { return false }
                count += 1
                return true
            }
        }

        func give() { count.withLock { $0 -= 1 } }
    }

    /// Shared by every caller in the app.
    static let maximumOutstanding = 16
    static let sharedBudget = Budget(limit: maximumOutstanding)

    private static let queue = DispatchQueue(
        label: "dev.noahqin.Corta.path-probe", qos: .userInitiated, attributes: .concurrent)

    /// The paths among `paths` that are directories, as far as `timeout`
    /// allows. `isDirectory` is the check itself, injected for tests.
    static func directories(
        among paths: some Collection<String>, timeout: DispatchTimeInterval,
        isDirectory: @escaping @Sendable (String) -> Bool = PathProbe.isDirectory,
        budget: Budget = PathProbe.sharedBudget
    ) -> Set<String> {
        let found = Mutex<Set<String>>([])
        let group = DispatchGroup()
        for path in Set(paths) {
            // Each check that never returns keeps a thread; past the cap a
            // path is not checked at all and counts as absent, rather than
            // drain the pool every other queue in the app draws on.
            guard budget.take() else { continue }
            group.enter()
            queue.async {
                if isDirectory(path) { found.withLock { _ = $0.insert(path) } }
                budget.give()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        return found.withLock { $0 }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func isRegularFile(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

/// Whether a `path:line` reference names a local file, answered off the
/// main thread for hover and click — each mouse move over such text used to
/// `stat` on the main thread. Answers are cached briefly. A check that has
/// not answered within `checkTimeout` is answered "no" (its caller is not
/// left waiting), and checks still blocked are capped, so a mount that never
/// answers costs a few threads, never the UI or later lookups.
@MainActor
final class FileReferenceProbe {
    static let shared = FileReferenceProbe()

    /// How long an answer stands: long enough for a hover's mouse moves, short
    /// enough that a file created a moment later is found.
    nonisolated static let lifetime: TimeInterval = 2
    /// How long a caller waits for a check before it counts as "no".
    nonisolated static let checkTimeout: Duration = .seconds(1)
    /// Checks blocked at once; past it a path is answered "no" unchecked.
    nonisolated static let maximumOutstanding = 8
    /// Callers waiting on one path; more are answered "no" at once.
    nonisolated static let maximumWaiters = 4

    private var answers: [String: (isFile: Bool, at: TimeInterval)] = [:]
    private var waiting: [String: [(Bool) -> Void]] = [:]
    private(set) var outstanding = 0
    private let check: @Sendable (String) -> Bool
    private let now: () -> TimeInterval
    private let timeout: Duration

    init(
        check: @escaping @Sendable (String) -> Bool = PathProbe.isRegularFile,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timeout: Duration = FileReferenceProbe.checkTimeout
    ) {
        self.check = check
        self.now = now
        self.timeout = timeout
    }

    /// The cached answer, or nil when there is none (yet).
    func cached(_ path: String) -> Bool? {
        guard let answer = answers[path], now() - answer.at < Self.lifetime else { return nil }
        return answer.isFile
    }

    /// Answers `then` exactly once: from the cache, from the check, or "no"
    /// when the check is late or cannot be started.
    func probe(_ path: String, then: @escaping (Bool) -> Void) {
        if let answer = cached(path) {
            then(answer)
            return
        }
        if waiting[path] != nil {
            guard waiting[path]!.count < Self.maximumWaiters else {
                then(false)
                return
            }
            waiting[path]?.append(then)
            return
        }
        guard outstanding < Self.maximumOutstanding else {
            then(false)
            return
        }
        waiting[path] = [then]
        outstanding += 1
        let check = check
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isFile = check(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outstanding -= 1
                self.finish(path, isFile: isFile)
            }
        }
        let timeout = timeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            // Late: answered "no" now; the real answer is cached when it comes.
            guard let self, self.waiting[path] != nil else { return }
            self.answer(path, isFile: false)
        }
    }

    private func finish(_ path: String, isFile: Bool) {
        answers[path] = (isFile, now())
        if answers.count > 256 {
            let current = now()
            answers = answers.filter { current - $0.value.at < Self.lifetime }
        }
        answer(path, isFile: isFile)
    }

    private func answer(_ path: String, isFile: Bool) {
        let callbacks = waiting.removeValue(forKey: path) ?? []
        for callback in callbacks { callback(isFile) }
    }
}
