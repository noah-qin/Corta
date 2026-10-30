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

import CoreServices
import Foundation

/// Watches the git directories of Space sessions and reads them off the main thread.
nonisolated final class GitStatusMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.noahqin.Corta.git", qos: .utility)
    private let lock = NSLock()
    private var directories: [UUID: String] = [:]
    private var watched: [String] = []
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    var onUpdate: (@MainActor @Sendable ([UUID: GitFacts]) -> Void)?

    func update(_ directories: [UUID: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let changed = directories != self.directories
            self.directories = directories
            self.lock.unlock()
            guard changed else { return }
            self.rewatch()
            self.scan()
        }
    }

    private func rewatch() {
        stopStream()
        lock.lock()
        let directories = self.directories
        lock.unlock()
        var paths = Set<String>()
        for directory in directories.values {
            guard let located = GitStatusReader.locate(URL(fileURLWithPath: directory, isDirectory: true)) else { continue }
            paths.insert(located.gitDir.path)
        }
        let sorted = paths.sorted()
        watched = sorted
        guard !sorted.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let created = FSEventStreamCreate(
            nil, Self.callback, &context, sorted as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<GitStatusMonitor>.fromOpaque(info).takeUnretainedValue().schedule()
    }

    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scan() {
        lock.lock()
        let directories = self.directories
        lock.unlock()
        var facts: [UUID: GitFacts] = [:]
        for (id, directory) in directories {
            if let read = GitStatusReader.read(directory: directory) { facts[id] = read }
        }
        let deliver = onUpdate
        DispatchQueue.main.async { deliver?(facts) }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stopStream() }
}
