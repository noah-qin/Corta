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

// MARK: - Local change detection

extension RemoteEditCoordinator {

    func watch(_ copy: RemoteEditStore.RemoteCopy) {
        unwatch(copy.id, invalidatingDigest: false)
        let url = store.localURL(for: copy)
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        let id = copy.id
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An editor's save is often several events and, for an atomic
            // save, a rename that retires the inode this descriptor holds —
            // so coalesce briefly, then re-point the watch and compare
            // content (the ConfigurationStore pattern).
            self.pendingChecks[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.repointWatch(copyID: id)
                Task { [weak self] in await self?.noteLocalWrite(copyID: id) }
            }
            self.pendingChecks[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watches[copy.id] = source
    }

    private func repointWatch(copyID: String) {
        guard pendingChecks[copyID] != nil else { return }
        pendingChecks[copyID] = nil
        guard let copy = store.copies[copyID] else { return }
        watch(copy)
    }

    func unwatch(_ copyID: String, invalidatingDigest: Bool = true) {
        if invalidatingDigest { digestChecks[copyID] = nil }
        pendingChecks[copyID]?.cancel()
        pendingChecks[copyID] = nil
        watches[copyID]?.cancel()
        watches[copyID] = nil
    }

    /// The watch handler's payload, separated so tests can drive it
    /// directly: a write whose content matches the approved digest is
    /// noise; anything else is an edit awaiting a decision. Internal, not
    /// private, for exactly that reason.
    func noteLocalWrite(copyID: String) async {
        guard let copy = store.copies[copyID] else { return }
        let check = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.checkLocalWrite(copyID: copyID, at: self.store.localURL(for: copy), check: check)
        }
        digestChecks[copyID] = DigestCheck(id: check, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A save event may have started a newer check while this one read.
        // In particular, `open` must not return before an immediate editor
        // save has reached the pending-decision state.
        while !Task.isCancelled, let latest = digestChecks[copyID] {
            await latest.task.value
        }
    }

    private func checkLocalWrite(copyID: String, at url: URL, check: UUID) async {
        defer {
            if digestChecks[copyID]?.id == check { digestChecks[copyID] = nil }
        }
        let result = await readDigest(at: url)
        guard !Task.isCancelled, digestChecks[copyID]?.id == check,
            let copy = store.copies[copyID]
        else { return }
        guard let digest = result else {
            // The copy was deleted underneath us: stop watching and drop
            // any pending decision about it.
            unwatch(copyID)
            pendingUploads.removeAll { $0.id == copyID }
            return
        }
        guard digest != digests[copyID] else { return }
        // Approve this state as the new baseline: Dismiss means "not this
        // edit", and the next save is measured against this content, not
        // against the download.
        digests[copyID] = digest
        guard !pendingUploads.contains(where: { $0.id == copyID }),
            !pendingConflicts.contains(where: { $0.id == copyID }),
            !uploadsInFlight.contains(copyID)
        else { return }
        let pending = PendingUpload(copy: copy, contentDigest: digest)
        pendingUploads.append(pending)
        presenter.promptUpload(pending)
    }

    /// File content I/O never inherits the UI actor, even with approachable
    /// concurrency enabled.
    @concurrent nonisolated func readDigest(at url: URL) async -> String? {
        RemoteEditStore.sha256Hex(ofFile: url)
    }

    func setDigest(_ digest: String?, for copyID: String) {
        digestChecks[copyID] = nil
        digests[copyID] = digest
    }

}
