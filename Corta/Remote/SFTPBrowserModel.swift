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
import Observation

/// Connection, directory navigation and file actions for the SFTP browser.
/// Transfer planning and lifecycle belong to `SFTPTransferQueue`.
/// Paths must be absolute; the server canonicalizes the initial directory.
@MainActor
@Observable
final class SFTPBrowserModel {
    #if DEBUG
    var isDevelopmentPreview = false
    #endif

    // MARK: - Entry model

    /// What one row of the listing is, decided from the ATTRS permission
    /// bits. `other` covers sockets, fifos and devices — displayed, but
    /// none of the operations pretend to know what to do with one.
    nonisolated enum Kind: Equatable {
        case file, directory, symlink, other

        var title: String {
            switch self {
            case .file: return L10n.text("sftp.kind.file")
            case .directory: return L10n.text("sftp.kind.directory")
            case .symlink: return L10n.text("sftp.kind.symlink")
            case .other: return L10n.text("sftp.kind.other")
            }
        }

        var symbolName: String {
            switch self {
            case .file: return "doc"
            case .directory: return "folder"
            case .symlink: return "link"
            case .other: return "questionmark.square.dashed"
            }
        }
    }

    nonisolated struct Entry: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let kind: Kind
        let size: UInt64?
        let modified: Date?
        /// The `drwxr-xr-x` rendering of the mode bits, when the server
        /// sent any.
        let permissions: String?

        /// Sort keys for the table's columns: a missing size or date sorts
        /// as the smallest, never as a crash or an arbitrary position.
        var sortSize: UInt64 { kind == .directory ? 0 : size ?? 0 }
        var sortModified: Date { modified ?? .distantPast }
        /// A dot file, hidden unless the browser is told to show them.
        var isHidden: Bool { name.hasPrefix(".") }
        /// The name as the table shows it (`SFTPBrowserModel.displayName`).
        var displayName: String { SFTPBrowserModel.displayName(name) }
    }

    /// The table's sort: a column and a direction. Folders stay above
    /// files whichever column is chosen, the way Finder lists them.
    nonisolated enum SortColumn: Equatable, Sendable {
        case name, size, modified
    }

    // MARK: - Connection state

    nonisolated enum ConnectionState: Equatable {
        /// Launched from a `.remoteUnknown` pane: the pane is remote, but
        /// no honest source names the host (the rule — never the
        /// launcher's argv, never the screen). The user types it.
        case needsHost
        case connecting
        case connected
        /// Carries the already-presented message; the state itself, not
        /// the error, is what the view shows.
        case failed(message: String)
    }

    /// Volume capacity for the status line. `unsupported` is a real answer
    /// (the server does not speak `statvfs@openssh.com`), displayed as
    /// unavailable — never as a zero.
    nonisolated enum VolumeStatus: Equatable {
        case unknown
        case unsupported
        case available(free: UInt64, total: UInt64)
    }

    typealias Transfer = SFTPTransferQueue.Transfer
    typealias ConflictPrompt = SFTPTransferQueue.ConflictPrompt
    typealias ConflictChoice = SFTPTransferQueue.ConflictChoice

    /// The confirmed-delete alert's content and payload.
    nonisolated struct DeleteConfirmation: Identifiable {
        let id = UUID()
        let entries: [Entry]
        /// Where the entries are, as named in the message: the listing may
        /// have moved on while the confirmation was being composed.
        let directory: String
        /// The connection the message named: a host change before the
        /// confirm must not run it against another machine.
        let connection: Int
        let title: String
        let message: String
    }

    /// The new-directory / rename sheet: one text field, one action.
    nonisolated struct TextPrompt: Identifiable {
        enum Action: Equatable {
            case newDirectory
            case rename(Entry)
        }

        let id = UUID()
        let action: Action
        let directory: String
        let connection: Int
        let title: String
        let message: String
        let initialText: String
    }

    /// What a download's destination choice means, from the picker: a save
    /// panel answers a full file URL (one file, possibly renamed), an
    /// open panel answers a directory the files land in by name.
    nonisolated enum DownloadDestination {
        case file(URL)
        case directory(URL)
    }

    // MARK: - Published state

    /// `nil` until a host is known — either from the pane (`.remote`) or
    /// typed in (`.needsHost`). An `SSHTarget.key`: it carries the user,
    /// port and key the connection is made with, and is what the window
    /// registry, the transfer queue and remote editing name it by.
    var host: String?
    /// The host as the window shows it.
    var displayHost: String? { host.map(SSHTarget.displayName(forKey:)) }
    /// The host step's form: host, user, port and key, as typed.
    var fields = SSHTargetFields()
    /// The form's host field alone.
    var hostField: String {
        get { fields.host }
        set { fields.host = newValue }
    }
    var connectionGeneration = 0
    var directoryGeneration = 0

    var connectionState: ConnectionState
    var currentPath = "/"
    /// The path field's text, kept in sync with `currentPath` on every
    /// successful navigation; only its commit navigates, so half-typed
    /// paths never fire listings.
    var pathField = "/"
    /// Every entry the server listed, in listing order; `entries` is what
    /// the table shows.
    var allEntries: [Entry] = []
    var entries: [Entry] = []
    var selection: Set<String> = []
    /// The table's sort, applied on every listing and whenever it changes.
    var sortColumn: SortColumn = .name { didSet { applyVisibleEntries() } }
    var sortAscending = true { didSet { applyVisibleEntries() } }
    /// Dot files are listed only on request; the toggle is per window.
    var showsHiddenFiles = false { didSet { applyVisibleEntries() } }
    /// How many dot files the current directory holds while they are hidden,
    /// so the status line can say so instead of the listing looking short.
    var hiddenEntryCount: Int {
        showsHiddenFiles ? 0 : allEntries.count(where: \.isHidden)
    }
    /// Directories visited before and after this one, newest last; Back and
    /// Forward walk them the way a browser's do.
    var backStack: [String] = []
    var forwardStack: [String] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isLoading = false
    /// A failed listing/mkdir/rename/delete: shown inline, leaving the
    /// current directory's contents in place.
    var listingError: String?
    var volumeStatus: VolumeStatus = .unknown
    var transfers: [Transfer] { transferQueue.transfers }

    /// The prompt states the view renders as sheets/alerts.
    var textPrompt: TextPrompt?
    var deleteConfirmation: DeleteConfirmation?
    var conflictPrompts: [ConflictPrompt] { transferQueue.conflictPrompts }

    // MARK: - Wiring (set by the controller; the model never sees AppKit)

    /// Panels, injected because presenting one is the controller's job and
    /// because tests then never open one. A `nil` answer is a cancelled
    /// panel and starts nothing.
    var pickUploadFiles: (() async -> [URL])?
    var pickDownloadDestination: (([Entry]) async -> DownloadDestination?)?
    /// Remote editing — opens a file row in the editor, on a managed
    /// local copy (`RemoteEditCoordinator` owns download, watch and the
    /// upload-back decision). Set by the controller; any error wording is
    /// handed back for the listing's error line.
    var onEditFile: ((Entry) -> Void)?
    /// Called with the window's title text whenever it should change.
    var onTitleChange: ((String) -> Void)?
    /// Called once the connection succeeded, with the host actually
    /// connected to — how a user-entered host becomes the registry key.
    var onConnected: ((String) -> Void)?
    /// Lets the window registry reuse a host before a second client starts.
    var shouldStartConnection: ((String) -> Bool)?
    /// The window gave up on a host — Cancel while connecting, or a retry
    /// under a different name — so the registry stops routing it here.
    var onHostAbandoned: ((String) -> Void)?

    let makeClient: @Sendable (String) -> any SFTPClient
    var client: (any SFTPClient)?
    let startDirectory: String?

    let transferQueue = SFTPTransferQueue()

    /// A host the pane *reported* but the user has not yet agreed to
    /// connect to (`RemoteHostConsent`): shown prefilled in the host field
    /// with wording that says where the name came from, and connected to
    /// only when the user says so. `nil` when there is no suggestion (a
    /// `.remoteUnknown` pane) or when `host` is already decided.
    let suggestedHost: String?

    init(
        host: String?,
        startDirectory: String?,
        suggestedHost: String? = nil,
        makeClient: (@Sendable (String) -> any SFTPClient)? = nil
    ) {
        self.host = host
        self.startDirectory = startDirectory
        self.suggestedHost = host == nil ? suggestedHost : nil
        if host == nil, let suggestedHost { fields = SSHTargetFields(host: suggestedHost) }
        self.makeClient = makeClient ?? { SFTPConnection.forApp(key: $0) }
        connectionState = host == nil ? .needsHost : .connecting
    }

    // MARK: - Title

    /// `host:path` once connected — the connection never learns the user
    /// (ssh's config owns that), so none is shown rather than one
    /// invented.
    /// The title for the window's first frame — `connect()` updates it on
    /// every state change after that, but a window opened on the
    /// host-entry step has had no state change yet and would otherwise sit
    /// untitled.
    func publishTitle() {
        updateTitle()
    }

    /// The window's title: the host once there is one — the path is the
    /// breadcrumb's to show, not repeated here.
    func updateTitle() {
        let title: String
        switch connectionState {
        case .needsHost:
            title = L10n.text("sftp.window.untitled")
        case .connecting, .connected, .failed:
            title = displayHost ?? L10n.text("sftp.window.untitled")
        }
        onTitleChange?(title)
    }


    // MARK: - Drags to Finder

    /// Staging folders made for drags to Finder; the controller removes
    /// them when the window closes.
    private(set) var dragStagingDirectories: [URL] = []

    /// A drag to Finder: downloads `entry` through the queue — so it has a
    /// progress row like any download — into a fresh private folder, and
    /// answers the file once it has landed. The system then copies it to
    /// wherever it was dropped. Files only; a folder is downloaded with
    /// Download, where its destination is chosen.
    func exportForDrag(_ entry: Entry) async throws -> URL {
        guard connectionState == .connected, entry.kind == .file,
            Self.isPlainEntryName(entry.name)
        else { throw SFTPTransferQueue.TransferFailure(message: L10n.text("sftp.drag.unavailable")) }
        let staging = try Self.makeDragStagingDirectory()
        dragStagingDirectories.append(staging)
        let remotePath = Self.joinPath(currentPath, entry.name)
        let local = staging.appendingPathComponent(Self.localFileName(entry.name))
        return try await withCheckedThrowingContinuation { continuation in
            transferQueue.enqueue(
                SFTPTransferQueue.Plan(
                    isUpload: false, remotePath: remotePath, localURL: local,
                    sourceSize: entry.size, sourceModified: entry.modified)
            ) { result in
                continuation.resume(with: result.mapError { $0 as any Error })
            }
        }
    }

    /// A new folder only this user can enter, under the temporary directory.
    nonisolated static func makeDragStagingDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Corta-SFTP-Drag", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Removes the drag staging folders; the window is closing.
    func removeDragStaging() {
        for folder in dragStagingDirectories {
            try? FileManager.default.removeItem(at: folder)
        }
        dragStagingDirectories.removeAll()
    }
}
