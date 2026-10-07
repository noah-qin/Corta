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
import Foundation

/// The one place the config file is read, written and watched (D10).
/// Changes write the file and apply what reads back, so a click and a
/// hand-edit take the same path.
///
/// Watches the file and the deepest existing ancestor of its directory:
/// editors save by rename, which the file's descriptor sees only as a
/// delete, and on first launch the directory may not exist yet.
@MainActor
final class ConfigurationStore {
    static let shared = ConfigurationStore(fileURL: ConfigurationStore.fileURL)

    /// Posted after any change; panes observe it, and new windows read.
    static let didChange = Notification.Name("dev.noahqin.Corta.configurationDidChange")

    /// Posted when a write fails and when a later one succeeds, for the
    /// settings page.
    static let writeStatusDidChange = Notification.Name(
        "dev.noahqin.Corta.configurationWriteStatusDidChange")

    private(set) var configuration = Configuration()
    /// Why the last write failed; nil after a success.
    private(set) var lastWriteError: Error?
    /// The file exists but cannot be read as UTF-8 text. Writes are refused
    /// until it can: writing would replace every setting in it with this
    /// run's defaults.
    private(set) var readError: Error?
    /// Other versions' keys, carried through writes.
    private var unknownKeys: [(String, String)] = []

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    /// Our last written text, so the watcher tells our own write from an
    /// external edit by content; a time window swallowed editor saves.
    private var lastWrittenText: String?
    private var pendingReload: DispatchWorkItem?

    /// Injected so tests use a temporary directory.
    let fileURL: URL

    /// `~/.config/corta/config`, unless a staged launch moved it (`AppPaths`).
    static var fileURL: URL { AppPaths.configFileURL }

    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
        startWatching()
    }

    isolated deinit {
        pendingReload?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    // MARK: - Reading

    /// Reads the file; absent means defaults, so nothing reports settings no
    /// file persists. Present but unreadable — permissions, or bytes that are
    /// not UTF-8 — keeps what is in memory and refuses writes until the file
    /// reads again: loaded as defaults, the next change in Settings wrote the
    /// defaults over every hand-made theme, binding and preset in it.
    func reload() {
        let text: String
        switch UserFile.readText(at: fileURL) {
        case .missing:
            setReadError(nil)
            unknownKeys = []
            let defaults = Configuration()
            guard configuration != defaults else { return }
            configuration = defaults
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        case .unreadable(let error):
            setReadError(error)
            return
        case .text(let contents):
            setReadError(nil)
            text = contents
        }
        let (parsed, unknown) = Configuration.parse(text)
        unknownKeys = unknown
        guard parsed != configuration else { return }
        configuration = parsed
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The refusal a write reports while the file is unreadable.
    struct UnreadableFileError: LocalizedError {
        let path: String
        var errorDescription: String? { L10n.format("settings.status.configUnreadable", path) }
    }

    /// Reported through the write status, which Settings shows: a change
    /// there is what the refusal stops.
    private func setReadError(_ error: Error?) {
        let wasUnreadable = readError != nil
        readError = error
        if error != nil {
            noteWriteResult(UnreadableFileError(path: fileURL.path))
        } else if wasUnreadable {
            noteWriteResult(nil)
        }
    }

    // MARK: - Writing

    /// Writes a change and reads it back; nothing sets `configuration`
    /// directly. A failed write is rolled back rather than kept in memory,
    /// where it wouldn't survive a relaunch; it posts `writeStatusDidChange`,
    /// not `didChange`. Returns whether it persisted.
    @discardableResult
    func update(_ mutate: (inout Configuration) -> Void) -> Bool {
        if readError != nil { reload() }
        var updated = configuration
        mutate(&updated)
        guard updated != configuration else { return true }
        let previous = configuration
        configuration = updated
        guard write() else {
            configuration = previous
            return false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    /// Creates the file with current values, for Reveal in Finder and a
    /// discoverable first launch.
    @discardableResult
    func write() -> Bool {
        // Read again first: a fix that leaves no write event — a `chmod` —
        // would otherwise keep writes refused until the next launch.
        if readError != nil { reload() }
        guard readError == nil else {
            noteWriteResult(UnreadableFileError(path: fileURL.path))
            return false
        }
        let url = fileURL
        let text = configuration.serialized(preserving: unknownKeys)
        do {
            // Through a symlink, so a dotfiles repository's copy stays the copy.
            try UserFile.write(text, to: url)
        } catch {
            noteWriteResult(error)
            return false
        }
        lastWrittenText = text
        noteWriteResult(nil)
        // The atomic write replaced the inode; re-watch.
        startWatching()
        return true
    }

    /// Posts only on a transition, not per successful keystroke.
    private func noteWriteResult(_ error: Error?) {
        let wasFailing = lastWriteError != nil
        lastWriteError = error
        guard wasFailing != (error != nil) else { return }
        NotificationCenter.default.post(name: Self.writeStatusDidChange, object: nil)
    }

    // MARK: - Watching

    private func startWatching() {
        fileSource?.cancel()
        directorySource?.cancel()
        // `.attrib` too: a `chmod` that makes an unreadable file readable.
        fileSource = watch(fileURL, mask: [.write, .extend, .delete, .rename, .attrib])
        directorySource = watch(
            Self.deepestExistingDirectory(under: fileURL.deletingLastPathComponent()),
            mask: [.write, .delete, .rename])
    }

    /// The nearest existing ancestor, whose write event announces the
    /// directory's creation.
    private static func deepestExistingDirectory(under url: URL) -> URL {
        var url = url
        while url.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: url.path)
        {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent)
        -> DispatchSourceFileSystemObject?
    {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Our own write needs no reload; compared by content so an external
            // edit right after it isn't swallowed.
            if let written = self.lastWrittenText {
                if (try? String(contentsOf: self.fileURL, encoding: .utf8)) == written {
                    return
                }
                // An external edit owns the file now.
                self.lastWrittenText = nil
            }
            // Coalesce, or a multi-event save is read mid-rewrite.
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadFromWatcher() }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func reloadFromWatcher() {
        // Re-watch before reading: an atomic save replaced the inode.
        startWatching()
        reload()
    }
}
