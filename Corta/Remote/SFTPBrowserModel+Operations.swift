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
    // MARK: - Directory operations

    /// What the view's toolbar asks for; the model composes the prompt,
    /// the view renders it and hands the typed text back.
    func requestNewDirectory() {
        guard connectionState == .connected else { return }
        textPrompt = TextPrompt(
            action: .newDirectory,
            directory: currentPath, connection: connectionGeneration,
            title: L10n.text("sftp.newDirectory.title"),
            message: L10n.format("sftp.newDirectory.message", currentPath),
            initialText: "")
    }

    func requestRename(_ entry: Entry) {
        guard connectionState == .connected else { return }
        textPrompt = TextPrompt(
            action: .rename(entry),
            directory: currentPath, connection: connectionGeneration,
            title: L10n.text("sftp.rename.title"),
            message: L10n.format("sftp.rename.message", entry.name),
            initialText: entry.name)
    }

    /// The text sheet's confirm. A name that is empty, `.`/`..`, or
    /// contains `/` is rejected before the server ever hears about it.
    func commitTextPrompt(_ text: String) {
        guard let prompt = textPrompt else { return }
        textPrompt = nil
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            listingError = L10n.text("sftp.name.invalid")
            return
        }
        guard let client, let host, prompt.connection == connectionGeneration else { return }
        // Navigation may finish behind the sheet; act on the directory it named.
        let directory = prompt.directory
        Task {
            do {
                switch prompt.action {
                case .newDirectory:
                    try await client.makeDirectory(path: Self.joinPath(directory, name))
                case .rename(let entry):
                    try await client.rename(
                        from: Self.joinPath(directory, entry.name),
                        to: Self.joinPath(directory, name))
                }
                guard prompt.connection == connectionGeneration else { return }
                refresh()
            } catch {
                guard prompt.connection == connectionGeneration else { return }
                listingError = Self.errorMessage(Self.sftpError(error), host: host)
            }
        }
    }

    /// Composes the delete confirmation: host and path always, and for a
    /// directory the number of entries inside it (best-effort — the count
    /// is a courtesy, the server's own answer is authoritative; rmdir
    /// refuses a non-empty directory and that refusal is shown as such).
    func requestDelete(_ entries: [Entry]) {
        guard connectionState == .connected, !entries.isEmpty, let client, let host = displayHost else { return }
        let directory = currentPath
        let connection = connectionGeneration
        Task {
            var contained = 0
            for entry in entries where entry.kind == .directory {
                if let listing = try? await client.listDirectory(
                    path: Self.joinPath(directory, entry.name))
                {
                    contained += max(0, listing.count - 2)  // "." and ".."
                }
            }
            let title = L10n.format("sftp.delete.title", host)
            let message: String
            if entries.count == 1, let entry = entries.first {
                let path = Self.joinPath(directory, entry.name)
                message =
                    entry.kind == .directory
                    ? L10n.format("sftp.delete.message.directory", path, host, contained)
                    : L10n.format("sftp.delete.message.file", path, host)
            } else {
                message = L10n.format("sftp.delete.message.multiple", entries.count, host)
            }
            deleteConfirmation = DeleteConfirmation(
                entries: entries, directory: directory, connection: connection,
                title: title, message: message)
        }
    }

    func confirmDelete() {
        guard let confirmation = deleteConfirmation else { return }
        deleteConfirmation = nil
        guard let client, let host, confirmation.connection == connectionGeneration else { return }
        // The directory the message named, not wherever the listing is now:
        // navigating while the count loaded made the same name another file.
        let directory = confirmation.directory
        Task {
            for entry in confirmation.entries {
                do {
                    let path = Self.joinPath(directory, entry.name)
                    if entry.kind == .directory {
                        try await client.removeDirectory(path: path)
                    } else {
                        try await client.remove(path: path)
                    }
                } catch {
                    listingError = Self.errorMessage(Self.sftpError(error), host: host)
                }
            }
            refresh()
        }
    }

    // MARK: - Transfers: entry points

    /// Upload via the injected file picker; a cancelled panel starts
    /// nothing.
    func requestUpload() {
        guard connectionState == .connected, let pickUploadFiles else { return }
        let directory = currentPath
        let connection = connectionGeneration
        Task {
            let urls = await pickUploadFiles()
            guard connection == connectionGeneration else { return }
            upload(urls, into: directory)
        }
    }

    /// Uploads local files and folders into `directory` (the current one by
    /// default) — the picker's answer, or what was dropped on the listing or
    /// on a folder row. Only file URLs are taken; a dropped link or text
    /// is not a file. Returns whether anything was queued.
    @discardableResult
    func upload(_ urls: [URL], into directory: String? = nil) -> Bool {
        guard connectionState == .connected else { return false }
        let target = directory ?? currentPath
        var queued = false
        for url in urls where url.isFileURL {
            // A chosen folder is a directory transfer — the whole tree,
            // one atomic file at a time, symbolic links skipped and
            // reported (`SFTPTransferEngine.uploadDirectory`).
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
            let name = url.lastPathComponent
            guard Self.isPlainEntryName(name) else { continue }
            transferQueue.enqueue(
                SFTPTransferQueue.Plan(
                    isUpload: true, isDirectory: isDirectory,
                    remotePath: Self.joinPath(target, name),
                    localURL: url))
            queued = true
        }
        return queued
    }

    /// Download via the injected destination picker (save panel for one
    /// file, directory chooser for several or for any directory). A chosen
    /// directory is a directory transfer: the whole tree, one atomic file
    /// at a time, into `<destination>/<name>`. Symbolic links are neither
    /// followed nor recreated; the engine reports them skipped.
    func requestDownload() {
        guard connectionState == .connected, let pickDownloadDestination else { return }
        let chosen = selectedEntries.filter { $0.kind == .file || $0.kind == .directory }
        guard !chosen.isEmpty else { return }
        // Where the chosen entries are, before the picker lets the listing move.
        let directory = currentPath
        Task {
            guard let destination = await pickDownloadDestination(chosen) else { return }
            for entry in chosen {
                let local: URL
                switch destination {
                case .file(let url):
                    local = url
                case .directory(let directory):
                    // `applyEntries` already refused anything but a plain
                    // component; asserted again at the one place the name
                    // becomes a local path.
                    guard Self.isPlainEntryName(entry.name) else { continue }
                    local = directory.appendingPathComponent(Self.localFileName(entry.name))
                }
                transferQueue.enqueue(
                    SFTPTransferQueue.Plan(
                        isUpload: false, isDirectory: entry.kind == .directory,
                        remotePath: Self.joinPath(directory, entry.name),
                        localURL: local,
                        sourceSize: entry.kind == .directory ? nil : entry.size,
                        sourceModified: entry.modified))
            }
        }
    }


    var selectedEntries: [Entry] {
        entries.filter { selection.contains($0.id) }
    }

    /// Whether Download has anything it can act on: files and directories
    /// both; a symbolic link or special file is not, since neither
    /// following it nor recreating it is what a download means.
    var canDownloadSelection: Bool {
        selectedEntries.contains { $0.kind == .file || $0.kind == .directory }
    }

    /// Edit acts on exactly one plain file. A symlink is excluded on
    /// purpose: whether the copy should track the link or its target is a
    /// question the UI has no answer for yet, so it does not pretend.
    var canEditSelection: Bool {
        selectedEntries.count == 1 && selectedEntries.first?.kind == .file
    }

    /// The Edit button. The coordinator call itself is the controller's
    /// wiring (`onEditFile`); errors come back through `listingError`.
    func requestEdit() {
        guard canEditSelection, let entry = selectedEntries.first else { return }
        onEditFile?(entry)
    }

    func resolveConflict(_ promptID: UUID, choice: ConflictChoice) {
        transferQueue.resolveConflict(promptID, choice: choice)
    }

    func cancelTransfer(_ id: UUID) { transferQueue.cancelTransfer(id) }
    func retryTransfer(_ id: UUID) { transferQueue.retryTransfer(id) }
}
