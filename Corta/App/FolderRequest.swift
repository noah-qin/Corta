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

/// A folder named from outside Corta — Finder's **New Corta Window Here**
/// service, `open -a Corta <folder>`, a folder dropped on the Dock icon —
/// checked before a window opens in it (`SECURITY.md` §4.6).
///
/// What crosses the boundary is a location, nothing else: an existing,
/// readable folder becomes the root pane's spawn directory. No route takes
/// text for the shell, a command or a preset name, and a file is refused
/// rather than opened in its parent.
///
/// The check `stat`s the path, which on a mount that stopped answering
/// blocks for minutes; it runs on `PathProbe` threads, bounded by the
/// restored-directory budget, and never on the main thread.
nonisolated enum FolderRequest {
    /// Why a named path opens no window.
    enum Refusal: Error, Equatable, Sendable {
        /// A URL that is not a file on this Mac.
        case notLocal(String)
        case missing(String)
        /// A file, or anything else that is not a folder.
        case notFolder(String)
        /// A folder this user cannot list or change into.
        case unreadable(String)
        /// The check did not answer within the budget: a disk that stopped
        /// answering, or more checks already outstanding than the cap.
        case noAnswer(String)
    }

    typealias Outcome = Result<String, Refusal>

    /// Folders one request opens at most; each is a window and a shell.
    static let maximumFolders = 10

    /// How long one request waits for its checks: a restored directory's.
    static var timeout: DispatchTimeInterval { SessionRestore.directoryCheckTimeout }

    /// The check itself, blocking; call it only off the main thread. A
    /// symbolic link to a folder is a folder, and keeps the name it was
    /// given.
    static func check(_ url: URL) -> Outcome {
        guard url.isFileURL else { return .failure(.notLocal(url.absoluteString)) }
        // Finder can hand over a file reference URL (`/.file/id=…`); its path
        // is the folder's only once resolved.
        let resolved = (url as NSURL).filePathURL ?? url
        let path = resolved.standardizedFileURL.path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(.missing(path))
        }
        guard isDirectory.boolValue else { return .failure(.notFolder(path)) }
        // Read to list it, search to change into it: what a shell started
        // there needs.
        guard access(path, R_OK | X_OK) == 0 else { return .failure(.unreadable(path)) }
        return .success(path)
    }

    /// The display name of what a URL names, for a refusal that has no
    /// checked path yet.
    static func displayPath(of url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    /// Each URL's outcome, in order, answered on the main actor. The checks
    /// run at once on probe threads under `budget` and are waited for on
    /// another, at most `timeout` in all; one that has not answered by then
    /// is `noAnswer`, and its thread finishes whenever its mount does.
    static func check(
        _ urls: [URL], timeout: DispatchTimeInterval = FolderRequest.timeout,
        budget: PathProbe.Budget = PathProbe.sharedBudget,
        check: @escaping @Sendable (URL) -> Outcome = FolderRequest.check,
        then: @escaping @MainActor @Sendable ([Outcome]) -> Void
    ) {
        PathProbe.run {
            let outcomes = checkWaiting(urls, timeout: timeout, budget: budget, check: check)
            Task { @MainActor in then(outcomes) }
        }
    }

    /// `check(_:timeout:budget:check:then:)`, waiting on the calling thread.
    static func checkWaiting(
        _ urls: [URL], timeout: DispatchTimeInterval, budget: PathProbe.Budget,
        check: @escaping @Sendable (URL) -> Outcome
    ) -> [Outcome] {
        let answers = Mutex<[Int: Outcome]>([:])
        let group = DispatchGroup()
        for (index, url) in urls.enumerated() {
            guard budget.take() else { continue }
            group.enter()
            PathProbe.run {
                let outcome = check(url)
                answers.withLock { $0[index] = outcome }
                budget.give()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        let answered = answers.withLock { $0 }
        return urls.indices.map { index in
            answered[index] ?? .failure(.noAnswer(displayPath(of: urls[index])))
        }
    }
}
