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
import CortaTerminal
import Foundation

extension SFTPBrowserModel {
    // MARK: - Navigation

    /// The path field's commit. Absolute paths only — relative input is
    /// rejected with its own message rather than resolved against a base
    /// the user cannot see.
    func navigate(to path: String) {
        guard client != nil, connectionState == .connected else { return }
        guard path.hasPrefix("/") else {
            listingError = L10n.text("sftp.path.notAbsolute")
            return
        }
        load(path)
    }

    func navigateInto(_ entry: Entry) {
        guard entry.kind == .directory else { return }
        load(Self.joinPath(currentPath, entry.name))
    }

    func navigateUp() {
        guard currentPath != "/" else { return }
        load(Self.parentPath(of: currentPath))
    }

    func navigateBack() {
        guard connectionState == .connected, let previous = backStack.last else { return }
        load(previous, history: .back)
    }

    func navigateForward() {
        guard connectionState == .connected, let next = forwardStack.last else { return }
        load(next, history: .forward)
    }

    func refresh() {
        guard connectionState == .connected else { return }
        load(currentPath, history: .none)
    }

    /// How a listing moves the history: a new visit clears Forward, Back
    /// and Forward trade one entry between the stacks, a refresh does
    /// neither. Applied only once the listing succeeds, so a directory
    /// that failed to open is never a step to go back to.
    private enum HistoryMove { case visit, back, forward, none }

    /// At most this many steps back; a long session's walk is not kept whole.
    private static let historyLimit = 50

    private func load(_ path: String, history: HistoryMove = .visit) {
        guard let client else { return }
        isLoading = true
        listingError = nil
        directoryGeneration += 1
        let generation = directoryGeneration
        Task {
            do {
                let listing = try await client.listDirectory(path: path)
                guard generation == directoryGeneration else { return }
                await applyEntries(listing) {
                    let destination = Self.normalized(path: path)
                    if destination != currentPath {
                        switch history {
                        case .visit:
                            backStack.append(currentPath)
                            forwardStack.removeAll()
                        case .back:
                            backStack.removeLast()
                            forwardStack.append(currentPath)
                        case .forward:
                            forwardStack.removeLast()
                            backStack.append(currentPath)
                        case .none:
                            break
                        }
                        if backStack.count > Self.historyLimit {
                            backStack.removeFirst(backStack.count - Self.historyLimit)
                        }
                    }
                    currentPath = destination
                    pathField = currentPath
                }
                guard generation == directoryGeneration else { return }
                selection = []
                updateTitle()
                await refreshVolume()
            } catch {
                guard generation == directoryGeneration else { return }
                listingError = Self.errorMessage(Self.sftpError(error), host: host ?? "")
                // A step that no longer opens (deleted, or its permissions
                // changed) is dropped, so Back and Forward do not stick on it
                // and what lies beyond stays reachable.
                let failed = Self.normalized(path: path)
                if history == .back, backStack.last == failed { backStack.removeLast() }
                if history == .forward, forwardStack.last == failed { forwardStack.removeLast() }
            }
            guard generation == directoryGeneration else { return }
            isLoading = false
        }
    }

    func refreshVolume() async {
        guard let client else { return }
        let connection = connectionGeneration
        let directory = directoryGeneration
        do {
            let info = try await client.volumeInfo(path: currentPath)
            guard connection == connectionGeneration, directory == directoryGeneration else { return }
            if let info {
                volumeStatus = Self.volumeStatus(for: info)
            } else {
                volumeStatus = .unsupported
            }
        } catch {
            guard connection == connectionGeneration, directory == directoryGeneration else { return }
            // Capacity is a nicety, not the listing: a failed statvfs
            // leaves the status line silent rather than replacing the
            // directory with an error.
            volumeStatus = .unknown
        }
    }

    /// Peer counters may use all 64 bits; invalid aggregates are unknown.
    /// `struct statvfs` counts blocks in units of `f_frsize`, not `f_bsize`.
    /// They differ on APFS — a 1 MiB block, a 4 KiB fragment — and reading
    /// the counts in blocks put a 650 GB Mac's free space at 168 TB. A
    /// server that reports no fragment size gets the block size.
    static func volumeStatus(for info: SFTPVolumeInfo) -> VolumeStatus {
        let unit = info.fragmentSize > 0 ? info.fragmentSize : info.blockSize
        let total = info.blocks.multipliedReportingOverflow(by: unit)
        let free = info.blocksAvailable.multipliedReportingOverflow(by: unit)
        guard !total.overflow, !free.overflow, free.partialValue <= total.partialValue else {
            return .unknown
        }
        return .available(free: free.partialValue, total: total.partialValue)
    }

    /// A remote name as the browser shows it. The server chose it, and a
    /// right-to-left override makes `invoice\u{202E}fdp.sh` read as
    /// `invoicehs.pdf`: controls and the scalars the grid also replaces
    /// (`ConcealingScalars`) show as U+FFFD. The name sent back is unchanged.
    nonisolated static func displayName(_ name: String) -> String {
        replacingConcealedScalars(in: name, with: "\u{FFFD}")
    }

    /// A remote name as a local file is called: the same scalars become `_`,
    /// so Finder never shows a reordered or hidden extension either.
    nonisolated static func localFileName(_ name: String) -> String {
        replacingConcealedScalars(in: name, with: "_")
    }

    /// Server text with controls and concealing scalars replaced — names
    /// here, sign-in prompts in `SSHAskpass.displayPrompt`, one rule for
    /// both. `keepingNewlines` leaves line feeds for text shown as lines.
    nonisolated static func replacingConcealedScalars(
        in name: String, with replacement: Unicode.Scalar, keepingNewlines: Bool = false
    ) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if keepingNewlines, scalar == "\n" {
                scalars.append(scalar)
                continue
            }
            let concealing =
                value < 0x20 || (0x7F...0x9F).contains(value) || ConcealingScalars.contains(value)
            scalars.append(concealing ? replacement : scalar)
        }
        return String(scalars)
    }

    /// Whether a name the server listed is one plain path component — the
    /// only thing a `READDIR` entry is allowed to be. A hostile server can
    /// send `../../.zshrc`, and a multi-file download would have appended
    /// that to the chosen local folder and written outside it; such an
    /// entry is dropped from the listing rather than shown, since nothing
    /// honest is on the other end of it.
    nonisolated static func isPlainEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0")
    }

    /// Conversion and natural sorting can take hundreds of milliseconds for a
    /// valid large listing. Only publication belongs on the main actor.
    func applyEntries(_ listing: [SFTPEntry], commit: () -> Void = {}) async {
        let connection = connectionGeneration
        let directory = directoryGeneration
        guard let converted = try? await Self.convertEntries(listing) else { return }
        while !Task.isCancelled {
            let hidden = showsHiddenFiles
            let column = sortColumn
            let ascending = sortAscending
            guard
                let result = try? await Self.prepareVisibleEntries(
                    converted.entries, hidden: hidden, column: column, ascending: ascending),
                connection == connectionGeneration, directory == directoryGeneration,
                !Task.isCancelled
            else { return }
            // Sort controls can change during the background pass. Recompute
            // with the newest controls before atomically publishing path + rows.
            guard hidden == showsHiddenFiles, column == sortColumn, ascending == sortAscending
            else { continue }
            entryPreparation?.cancel()
            entryPreparation = nil
            entryGeneration &+= 1
            allEntries = converted.entries
            hiddenEntries = converted.hiddenCount
            entries = result.entries
            selection.formIntersection(result.names)
            commit()
            return
        }
    }

    @concurrent
    private static func convertEntries(_ listing: [SFTPEntry]) async throws
        -> (entries: [Entry], hiddenCount: Int)
    {
        var entries: [Entry] = []
        var hiddenCount = 0
        for entry in listing {
            try Task.checkCancellation()
            guard let name = entry.filenameIfUTF8, Self.isPlainEntryName(name) else { continue }
            let attributes = entry.attributes
            entries.append(
                Entry(
                    name: name, kind: Self.kind(ofPermissions: attributes.permissions),
                    size: attributes.size,
                    modified: attributes.modificationTime.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    permissions: attributes.permissions.map(Self.permissionString)))
            if name.hasPrefix(".") { hiddenCount += 1 }
        }
        return (entries, hiddenCount)
    }

    /// Superseded sorts stop in the comparator; late results cannot replace
    /// a newer directory, connection, hidden-file choice or sort order.
    func applyVisibleEntries() {
        entryPreparation?.cancel()
        entryGeneration &+= 1
        let generation = entryGeneration
        let source = allEntries
        let hidden = showsHiddenFiles
        let column = sortColumn
        let ascending = sortAscending
        entryPreparation = Task { [weak self] in
            guard
                let result = try? await Self.prepareVisibleEntries(
                    source, hidden: hidden, column: column, ascending: ascending),
                !Task.isCancelled, let self, generation == self.entryGeneration
            else { return }
            self.entries = result.entries
            self.selection.formIntersection(result.names)
            self.entryPreparation = nil
        }
    }

    @concurrent
    private static func prepareVisibleEntries(
        _ entries: [Entry], hidden: Bool, column: SortColumn, ascending: Bool
    ) async throws -> (entries: [Entry], names: Set<String>) {
        try Task.checkCancellation()
        let visible = hidden ? entries : entries.filter { !$0.isHidden }
        let sorted = try Self.sorted(
            visible, by: column, ascending: ascending, checkCancellation: true)
        try Task.checkCancellation()
        return (sorted, Set(sorted.map(\.id)))
    }

    /// Folders first, then the column; ties fall back to the name, so the
    /// order is total and the same listing always lands the same way.
    nonisolated private static func sorted(
        _ entries: [Entry], by column: SortColumn, ascending: Bool, checkCancellation: Bool
    ) throws -> [Entry] {
        try entries.sorted { lhs, rhs in
            if checkCancellation { try Task.checkCancellation() }
            if (lhs.kind == .directory) != (rhs.kind == .directory) {
                return lhs.kind == .directory
            }
            let order: ComparisonResult
            switch column {
            case .name: order = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                order =
                    lhs.sortSize == rhs.sortSize
                    ? .orderedSame : (lhs.sortSize < rhs.sortSize ? .orderedAscending : .orderedDescending)
            case .modified: order = lhs.sortModified.compare(rhs.sortModified)
            }
            if order == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
