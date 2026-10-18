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

import Dispatch
import Foundation
import Synchronization
import Testing

@testable import Corta

@MainActor
struct RemoteEditConcurrencyTests {
    @Test("a slow file read leaves the main actor free and cannot replace a newer digest")
    func staleDigestDoesNotReplaceNewerEdit() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let copy = store.recordDownload(host: "host", remotePath: "/file", remoteSize: 3, remoteMTime: 1)
        let url = store.localURL(for: copy)
        try store.secureCopy(at: url)
        try Data("old".utf8).write(to: url)
        let started = Mutex(false)
        let calls = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let coordinator = RemoteEditCoordinator(
            store: store,
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }),
            hashFile: { url in
                #expect(!Thread.isMainThread, "file content must be read off the UI thread")
                let call = calls.withLock { $0 += 1; return $0 }
                let digest = RemoteEditStore.sha256Hex(ofFile: url)
                if call == 1 {
                    started.withLock { $0 = true }
                    #expect(release.wait(timeout: .now() + 5) == .success)
                }
                return digest
            })
        let first = Task { await coordinator.noteLocalWrite(copyID: copy.id) }
        await waitUntil("first read suspended off the main actor") { started.withLock { $0 } }
        // This runs while the first read is held: the UI actor is available.
        try Data("new".utf8).write(to: url)
        await coordinator.noteLocalWrite(copyID: copy.id)
        let expected = RemoteEditStore.sha256Hex(Data("new".utf8))
        #expect(coordinator.pendingUploads.first?.contentDigest == expected)
        release.signal()
        await first.value
        #expect(coordinator.digests[copy.id] == expected)
        #expect(coordinator.pendingUploads.count == 1)
    }

    @Test("re-baselining while a check is in flight discards the old result")
    func staleDigestDoesNotUndoBaseline() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let copy = store.recordDownload(host: "host", remotePath: "/file", remoteSize: 3, remoteMTime: 1)
        let url = store.localURL(for: copy)
        try store.secureCopy(at: url)
        try Data("old".utf8).write(to: url)
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let coordinator = RemoteEditCoordinator(
            store: store,
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }),
            hashFile: { url in
                let digest = RemoteEditStore.sha256Hex(ofFile: url)
                started.withLock { $0 = true }
                #expect(release.wait(timeout: .now() + 5) == .success)
                return digest
            })
        let check = Task { await coordinator.noteLocalWrite(copyID: copy.id) }
        await waitUntil("read started") { started.withLock { $0 } }
        coordinator.setDigest("approved-new-content", for: copy.id)
        release.signal()
        await check.value
        #expect(coordinator.digests[copy.id] == "approved-new-content")
        #expect(coordinator.pendingUploads.isEmpty)
    }
}
