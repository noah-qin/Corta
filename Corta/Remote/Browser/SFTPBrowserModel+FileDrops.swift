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

import AppKit

extension SFTPBrowserModel {
    func receiveFileDrop(_ pasteboard: NSPasteboard, into destination: String) -> Bool {
        let generation = connectionGeneration
        let id = UUID()
        let request = FileDropRequest.start(pasteboard) { [weak self] result in
            guard let self else { FileDropStorage.remove(result.directory); return }
            self.fileDropRequests[id] = nil
            self.finishReception(result, into: destination, generation: generation)
        }
        guard let request else { listingError = L10n.text("drop.failed"); return false }
        fileDropRequests[id] = request
        return true
    }

    func finishReception(_ result: FileDropRequest.Result, into destination: String, generation: Int) {
        guard connectionGeneration == generation, connectionState == .connected else {
            FileDropStorage.remove(result.directory)
            listingError = L10n.text("drop.connectionChanged")
            return
        }
        if let directory = result.directory {
            receivedDropDirectories[directory] = Set(result.urls.filter {
                $0.path.hasPrefix(directory.path + "/")
            })
        }
        receptionNotice = nil
        guard !result.urls.isEmpty, upload(result.urls, into: destination) else {
            FileDropStorage.remove(result.directory)
            if let directory = result.directory { receivedDropDirectories[directory] = nil }
            listingError = result.notice ?? L10n.text("drop.failed")
            return
        }
        receptionNotice = result.notice
    }

    /// Successful uploads, including retries, release only Corta-owned
    /// promise sources. Failed sources stay available for Retry until close.
    func cleanUploadedDropCopies() {
        let done = Set(transferQueue.transfers.compactMap { transfer -> URL? in
            guard transfer.isUpload, case .done = transfer.state else { return nil }
            return transfer.localURL
        })
        removeDropCopies(done)
    }

    func clearFinishedTransfers() {
        let candidates = Set(transfers.filter { $0.isUpload && $0.isFinished }.map(\.localURL))
        transferQueue.clearFinished()
        removeDropCopies(candidates)
    }

    private func removeDropCopies(_ candidates: Set<URL>) {
        let retained = Set(transfers.compactMap { transfer -> URL? in
            guard transfer.isUpload else { return nil }
            if !transfer.isFinished { return transfer.localURL }
            if case .failed(_, true) = transfer.state { return transfer.localURL }
            return nil
        })
        let removable = candidates.subtracting(retained)
        for (directory, urls) in receivedDropDirectories {
            for url in urls.intersection(removable) { FileDropStorage.remove(url) }
            let remaining = urls.subtracting(removable)
            if remaining.isEmpty {
                FileDropStorage.remove(directory)
                receivedDropDirectories[directory] = nil
            } else {
                receivedDropDirectories[directory] = remaining
            }
        }
    }

    func removeReceivedDrops() {
        for request in fileDropRequests.values { request.cancel() }
        fileDropRequests.removeAll()
        for directory in receivedDropDirectories.keys { FileDropStorage.remove(directory) }
        receivedDropDirectories.removeAll()
        receptionNotice = nil
    }

}
