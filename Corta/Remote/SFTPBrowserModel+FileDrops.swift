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
            guard self.connectionGeneration == generation, self.connectionState == .connected else {
                FileDropStorage.remove(result.directory)
                self.listingError = L10n.text("drop.targetChanged")
                return
            }
            if let notice = result.notice { self.listingError = notice }
            if let directory = result.directory {
                self.receivedDropDirectories[directory] = Set(result.urls.filter {
                    $0.path.hasPrefix(directory.path + "/")
                })
            }
            if !self.upload(result.urls, into: destination) {
                FileDropStorage.remove(result.directory)
                if let directory = result.directory { self.receivedDropDirectories[directory] = nil }
                self.listingError = L10n.text("drop.failed")
            }
        }
        guard let request else { listingError = L10n.text("drop.failed"); return false }
        fileDropRequests[id] = request
        return true
    }

    /// Successful uploads, including retries, release only Corta-owned
    /// promise sources. Failed sources stay available for Retry until close.
    func cleanUploadedDropCopies() {
        let done = Set(transferQueue.transfers.compactMap { transfer -> URL? in
            guard transfer.isUpload, case .done = transfer.state else { return nil }
            return transfer.localURL
        })
        for (directory, urls) in receivedDropDirectories {
            for url in urls.intersection(done) { FileDropStorage.remove(url) }
            let remaining = urls.subtracting(done)
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
    }

}
