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

extension SFTPBrowserModel {
    // MARK: - Connect

    /// Starts (or retries, after a failure) the connection. With no host
    /// yet, the typed one is adopted; an empty field is a no-op. The guard
    /// is the client, not the state: a fresh model with a known host
    /// *starts* in `.connecting` (so the window shows progress from its
    /// first frame), and `.failed` clears the client, which is what makes
    /// Retry work. A live or in-flight connection is returned to as-is —
    /// re-presenting an open window must not spawn a second session.
    func connect() {
        guard client == nil else { return }
        // `hostField` is consent only when the user submits it — a
        // presenter must not call this on a `.needsHost` model with a
        // prefilled suggestion (`SFTPBrowserController.present`).
        let name: String
        if let host {
            name = host
        } else {
            guard !fields.isEmpty else { return }
            switch fields.target {
            case .success(let target):
                host = target.key
                name = target.key
            case .failure(let problem):
                connectionState = .failed(message: RemoteConnectForm.message(problem))
                updateTitle()
                return
            }
        }
        // The check every other way to name a host passes (`SSHTarget`):
        // this field and a pane's OSC 7 report reached ssh's argv without it,
        // leaving ssh's own hostname rules as the only guard.
        guard SSHTarget(key: name) != nil else {
            // As `changeHost` leaves a name: released, and the title no
            // longer showing it.
            onHostAbandoned?(name)
            host = nil
            fill(from: name)
            connectionState = .failed(message: RemoteConnectForm.message(.host))
            updateTitle()
            return
        }
        guard shouldStartConnection?(name) != false else { return }
        connectionState = .connecting
        listingError = nil
        updateTitle()
        let client = makeClient(name)
        self.client = client
        transferQueue.client = client
        transferQueue.host = name
        transferQueue.onUploadFinished = { [weak self] in self?.refresh() }
        transferQueue.onListingError = { [weak self] in self?.listingError = $0 }
        connectionGeneration += 1
        let generation = connectionGeneration
        Task { await self.performConnect(client: client, host: name, generation: generation) }
    }

    private func performConnect(client: any SFTPClient, host name: String, generation: Int) async {
        do {
            _ = try await client.connect()
            // The pane's reported directory when there is one; otherwise
            // the session's own starting directory, canonicalised by the
            // server — never a guess at "~".
            let path: String
            if let startDirectory {
                path = startDirectory
            } else {
                path = try await client.realPath(path: ".")
            }
            let listing = try await client.listDirectory(path: path)
            guard generation == connectionGeneration else { client.close(); return }
            connectionState = .connected
            // A new connection starts a new walk: folders visited on another
            // host, or before a reconnect, are not steps back on this one.
            backStack.removeAll()
            forwardStack.removeAll()
            currentPath = Self.normalized(path: path)
            pathField = currentPath
            applyEntries(listing)
            onConnected?(name)
            await refreshVolume()
        } catch {
            guard generation == connectionGeneration else { return }
            let error = Self.sftpError(error)
            connectionState = .failed(message: Self.errorMessage(error, host: name))
            // Left in the fields, so the destination that failed can be
            // corrected.
            fill(from: name)
            client.close()
            self.client = nil
        }
        updateTitle()
    }

    /// Closes the session and abandons every transfer. Called by the
    /// controller when the window closes.
    func disconnect() {
        connectionGeneration += 1
        directoryGeneration += 1
        isLoading = false
        transferQueue.disconnect()
        client?.close()
        client = nil
    }

    func changeHost() {
        disconnect()
        backStack.removeAll()
        forwardStack.removeAll()
        if let host {
            fill(from: host)
            onHostAbandoned?(host)
        }
        host = nil
        connectionState = .needsHost
        updateTitle()
    }

    /// Connect again after a failure — under the name now in the field,
    /// which the user may have corrected.
    func retry() {
        guard isFailed else { return }
        let typed = fields
        // The key is part of it: a key chosen or cleared after a failure is
        // a different connection, even to the same place.
        if !typed.isEmpty, (try? typed.target.get())?.key != host {
            changeHost()
            fields = typed
        }
        connect()
    }

    /// Cancel while connecting, or Edit after a failure: back to the host
    /// field, with the name that was tried left in it to correct. A hung
    /// host is never a window the user can only close.
    func cancelConnect() {
        guard connectionState == .connecting || isFailed else { return }
        changeHost()
    }

    /// The form's fields for a connection's key, to correct and retry.
    private func fill(from name: String) {
        fields = SSHTarget(key: name).map(SSHTargetFields.init) ?? SSHTargetFields(host: name)
    }

    var isFailed: Bool {
        if case .failed = connectionState { return true }
        return false
    }
}
