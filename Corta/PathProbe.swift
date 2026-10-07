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
    private static let queue = DispatchQueue(
        label: "dev.noahqin.Corta.path-probe", qos: .userInitiated, attributes: .concurrent)

    /// The paths among `paths` that are directories, as far as `timeout`
    /// allows. `isDirectory` is the check itself, injected for tests.
    static func directories(
        among paths: some Collection<String>, timeout: DispatchTimeInterval,
        isDirectory: @escaping @Sendable (String) -> Bool = PathProbe.isDirectory
    ) -> Set<String> {
        let found = Mutex<Set<String>>([])
        let group = DispatchGroup()
        for path in Set(paths) {
            group.enter()
            queue.async {
                if isDirectory(path) { found.withLock { _ = $0.insert(path) } }
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
/// `stat` on the main thread. Answers are cached briefly; a mount that never
/// answers holds at most `maximumInFlight` probes, never the UI.
@MainActor
final class FileReferenceProbe {
    static let shared = FileReferenceProbe()

    /// How long an answer stands: long enough for a hover's mouse moves, short
    /// enough that a file created a moment later is found.
    nonisolated static let lifetime: TimeInterval = 2
    nonisolated static let maximumInFlight = 8

    private var answers: [String: (isFile: Bool, at: TimeInterval)] = [:]
    private var waiting: [String: [(Bool) -> Void]] = [:]
    private let check: @Sendable (String) -> Bool
    private let now: () -> TimeInterval

    init(
        check: @escaping @Sendable (String) -> Bool = PathProbe.isRegularFile,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.check = check
        self.now = now
    }

    /// The cached answer, or nil when there is none (yet).
    func cached(_ path: String) -> Bool? {
        guard let answer = answers[path], now() - answer.at < Self.lifetime else { return nil }
        return answer.isFile
    }

    /// Answers `then` — at once from the cache, otherwise once the background
    /// check returns. With every slot held by checks that have not returned,
    /// nothing is started and `then` is never called.
    func probe(_ path: String, then: @escaping (Bool) -> Void) {
        if let answer = cached(path) {
            then(answer)
            return
        }
        if waiting[path] != nil {
            waiting[path]?.append(then)
            return
        }
        guard waiting.count < Self.maximumInFlight else { return }
        waiting[path] = [then]
        let check = check
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isFile = check(path)
            Task { @MainActor [weak self] in self?.finish(path, isFile: isFile) }
        }
    }

    private func finish(_ path: String, isFile: Bool) {
        answers[path] = (isFile, now())
        if answers.count > 256 {
            let current = now()
            answers = answers.filter { current - $0.value.at < Self.lifetime }
        }
        let callbacks = waiting.removeValue(forKey: path) ?? []
        for callback in callbacks { callback(isFile) }
    }
}
