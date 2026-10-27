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

import Darwin
import Foundation
import Synchronization
import Testing

/// A tiny remote filesystem: flat maps of paths, POSIX-enough for the
/// transfer engine's needs (sizes, mtimes, directories, existence).
final class FakeRemoteFileSystem: @unchecked Sendable {
    struct File: Equatable {
        var data: [UInt8]
        var modificationTime: UInt32 = 1_000
        var permissions: UInt32 = 0o100_644
    }

    private struct State {
        var files: [String: File] = [:]
        var directories: Set<String> = ["/"]
    }

    private let state = Mutex(State())

    func createFile(_ path: String, data: [UInt8], modificationTime: UInt32 = 1_000) {
        state.withLock { state in
            state.files[path] = File(data: data, modificationTime: modificationTime)
            // Ancestor directories exist implicitly, the way a real
            // filesystem's would.
            var ancestor = path
            while let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex {
                ancestor = String(ancestor[ancestor.startIndex..<slash])
                state.directories.insert(ancestor)
            }
        }
    }

    func createDirectory(_ path: String) {
        _ = state.withLock { $0.directories.insert(path) }
    }

    func file(_ path: String) -> File? { state.withLock { $0.files[path] } }
    func isDirectory(_ path: String) -> Bool { state.withLock { $0.directories.contains(path) } }
    func exists(_ path: String) -> Bool {
        state.withLock { $0.files.keys.contains(path) || $0.directories.contains(path) }
    }

    func removeFile(_ path: String) {
        _ = state.withLock { $0.files.removeValue(forKey: path) }
    }

    func rename(from oldName: String, to newName: String) {
        state.withLock { state in
            if let file = state.files.removeValue(forKey: oldName) {
                state.files[newName] = file
            }
        }
    }

    /// The names directly under a directory, or nil if it is not one.
    func children(of path: String) -> [String]? {
        state.withLock { state -> [String]? in
            guard state.directories.contains(path) else { return nil }
            let prefix = path == "/" ? "/" : path + "/"
            var names: Set<String> = []
            for candidate in Set(state.files.keys).union(state.directories) {
                guard candidate != path, candidate.hasPrefix(prefix) else { continue }
                let rest = String(candidate.dropFirst(prefix.count))
                guard !rest.isEmpty, !rest.contains("/") else { continue }
                names.insert(rest)
            }
            return names.sorted()
        }
    }
}
