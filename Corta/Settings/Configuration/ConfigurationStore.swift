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
import Synchronization

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
    private var pendingReloadSince: TimeInterval = 0
    private static let longestReloadDelay: TimeInterval = 1
    private var pendingReload: DispatchWorkItem?
    /// The file's text as this store last read or wrote it; nil when it was
    /// absent. A write compares the file with it first, so an edit the
    /// watcher has not delivered yet is read in, not written over.
    private var syncedText: String?

    /// Injected so tests use a temporary directory.
    let fileURL: URL

    /// `~/.config/corta/config`, unless a staged launch moved it (`AppPaths`).
    static var fileURL: URL { AppPaths.configFileURL }

    /// The largest file read: the file is parsed on the main thread, and a
    /// complete one is a few kilobytes. Larger is treated as unreadable —
    /// kept, reported, writes refused (`CONFIGURATION.md`).
    nonisolated static let maximumFileBytes = 1 << 20

    /// How long the main thread waits for the file. A dotfiles symlink can put
    /// it on a mount that stops answering, and `read` then blocks for minutes.
    static let fileAccessTimeout: DispatchTimeInterval = .seconds(1)
    /// How soon a file that did not answer is asked again.
    static let retryAfterTimeout: TimeInterval = 5
    /// Its own: a hung mount takes these few threads, not the shared budget
    /// the rest of the app's checks draw on. No room counts as no answer.
    private let accessBudget = PathProbe.Budget(limit: 2)
    private let readFile: @Sendable (URL) -> UserFile.ReadResult
    private let fileAccessTimeout: DispatchTimeInterval
    private let retryDelay: TimeInterval
    private var retry: DispatchWorkItem?
    private var watchGeneration = 0
    private var writePending = false

    init(
        fileURL: URL,
        readFile: @escaping @Sendable (URL) -> UserFile.ReadResult = {
            UserFile.readText(at: $0, maximumBytes: ConfigurationStore.maximumFileBytes)
        },
        fileAccessTimeout: DispatchTimeInterval = ConfigurationStore.fileAccessTimeout,
        retryDelay: TimeInterval = ConfigurationStore.retryAfterTimeout
    ) {
        self.fileURL = fileURL
        self.readFile = readFile
        self.fileAccessTimeout = fileAccessTimeout
        self.retryDelay = retryDelay
        reload()
        if !(readError is TimedOutError) { startWatching() }
    }

    /// The file did not answer in time: no more known than an unreadable one,
    /// and treated as one. What is in memory stays and writes are refused,
    /// never defaults written over a file nobody could read.
    struct TimedOutError: LocalizedError {
        var errorDescription: String? { L10n.text("settings.status.configTimedOut") }
    }

    /// The file's contents, waited for at most `fileAccessTimeout`.
    private func readFileBounded() -> UserFile.ReadResult {
        let (url, read) = (fileURL, readFile)
        let answer = PathProbe.answer(timeout: fileAccessTimeout, budget: accessBudget) {
            SendableRead(result: read(url))
        }
        return answer?.result ?? .unreadable(TimedOutError())
    }

    private struct SendableRead: @unchecked Sendable { let result: UserFile.ReadResult }

    /// While the file has not answered, ask again; a mount coming back
    /// delivers no event to a watcher that could not open it.
    private func scheduleRetry() {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.reload()
            if self.readError == nil, self.fileSource == nil || self.directorySource == nil { self.startWatching() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    isolated deinit {
        pendingReload?.cancel()
        retry?.cancel()
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
        apply(readFileBounded())
    }

    private func apply(_ read: UserFile.ReadResult) {
        let text: String
        switch read {
        case .missing:
            setReadError(nil)
            syncedText = nil
            unknownKeys = []
            let defaults = Configuration()
            guard configuration != defaults else { return }
            configuration = defaults
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        case .unreadable(let error):
            setReadError(error)
            if error is TimedOutError { scheduleRetry() }
            return
        case .text(let contents):
            setReadError(nil)
            text = contents
            syncedText = contents
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
        if let error = error as? UserFile.TooLargeError {
            noteWriteResult(error)
        } else if error != nil {
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
    ///
    /// The change is applied to the file as it is now. A watcher event is
    /// delivered a moment after the save it reports, and a change made in
    /// that moment used to serialise the stale copy in memory — writing an
    /// external edit back out. The mutation touches only the settings it
    /// changes, so an external edit to any other setting survives; on the
    /// same setting the later one, this change, wins. Two processes writing
    /// at the same instant are not serialised: the file has no lock.
    @discardableResult
    func update(_ mutate: (inout Configuration) -> Void) -> Bool {
        guard !writePending else { return false }
        syncWithFile()
        var updated = configuration
        mutate(&updated)
        guard updated != configuration else { return true }
        let previous = configuration
        configuration = updated
        guard persist() else {
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
        guard !writePending else { return false }
        // Read again first: a fix that leaves no write event — a `chmod` —
        // would otherwise keep writes refused until the next launch, and an
        // edit not yet delivered would be written over.
        syncWithFile()
        return persist()
    }

    /// Creates the file with current values when there is none, for a
    /// discoverable first launch; an existing file is left as written.
    /// Opening Settings used to rewrite it every time, which rearranged a
    /// hand-made file even when nothing was changed.
    @discardableResult
    func createIfMissing() -> Bool {
        guard !writePending else { return false }
        syncWithFile()
        guard readError == nil else { return false }
        guard syncedText == nil else { return true }
        return persist()
    }

    /// Reads in the file if it differs from what this store last read or
    /// wrote, or could not be read then. One read, so one wait at most.
    private func syncWithFile() {
        let read = readFileBounded()
        let changed: Bool
        switch read {
        case .missing: changed = syncedText != nil
        case .unreadable: changed = true
        case .text(let contents): changed = contents != syncedText
        }
        if readError != nil || changed { apply(read) }
    }

    /// Serialises the configuration in memory over the file.
    private func persist() -> Bool {
        guard readError == nil else {
            noteWriteResult(readError as? UserFile.TooLargeError ?? UnreadableFileError(path: fileURL.path))
            return false
        }
        let url = fileURL
        let text = configuration.serialized(preserving: unknownKeys)
        let mayCommit = Mutex(true)
        var started = true
        let result = PathProbe.answer(timeout: fileAccessTimeout, budget: accessBudget, abandoned: {
            [weak self] (late: Result<Void, any Error>) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writePending = false
                if case .success = late { self.noteWriteResult(nil) }
                // If rename was already in progress when the wait expired,
                // reload whichever file the filesystem actually committed.
                self.startWatching()
            }
        }, onBudgetExhausted: { started = false }) {
            Result { try UserFile.write(text, to: url) { mayCommit.withLock { $0 } } }
        }
        guard let result else {
            mayCommit.withLock { $0 = false }
            writePending = started
            noteWriteResult(TimedOutError())
            return false
        }
        if case .failure(let error) = result {
            noteWriteResult(error)
            return false
        }
        syncedText = text
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
        fileSource = nil
        directorySource = nil
        // Off the main thread, like the read: `open` and the walk up the path
        // block on a mount that has stopped answering. Late descriptors close.
        let (file, directory) = (fileURL, fileURL.deletingLastPathComponent())
        let timeout = fileAccessTimeout
        let budget = accessBudget
        watchGeneration += 1
        let generation = watchGeneration
        PathProbe.run { [weak self] in
            let opened = PathProbe.answer(timeout: timeout, budget: budget, abandoned: { $0.closeBoth() }) {
                WatchDescriptors(
                    file: open(file.path, O_EVTONLY | O_CLOEXEC),
                    directory: open(Self.deepestExistingDirectory(under: directory).path, O_EVTONLY | O_CLOEXEC))
            }
            Task { @MainActor [weak self] in
                guard let self, self.watchGeneration == generation else {
                    opened?.closeBoth()
                    return
                }
                guard let opened else {
                    self.scheduleRetry()
                    return
                }
                self.fileSource = self.watch(opened.file, mask: [.write, .extend, .delete, .rename, .attrib])
                self.directorySource = self.watch(opened.directory, mask: [.write, .delete, .rename])
                // Catch an edit in the gap between the first read and the
                // watcher opening, after the watchers can observe new edits.
                self.reloadAfterWatchInstallation(generation: generation)
            }
        }
    }

    private func reloadAfterWatchInstallation(generation: Int) {
        let (url, read, timeout, budget) = (fileURL, readFile, fileAccessTimeout, accessBudget)
        PathProbe.run { [weak self] in
            let result = PathProbe.answer(timeout: timeout, budget: budget) { read(url) }
            Task { @MainActor [weak self] in
                guard let self, self.watchGeneration == generation else { return }
                self.apply(result ?? .unreadable(TimedOutError()))
            }
        }
    }

    private struct WatchDescriptors: Sendable {
        let file: Int32
        let directory: Int32

        nonisolated func closeBoth() {
            if file >= 0 { close(file) }
            if directory >= 0 { close(directory) }
        }
    }

    /// The nearest existing ancestor, whose write event announces the
    /// directory's creation.
    private nonisolated static func deepestExistingDirectory(under url: URL) -> URL {
        var url = url
        while url.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: url.path)
        {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func watch(_ descriptor: Int32, mask: DispatchSource.FileSystemEvent)
        -> DispatchSourceFileSystemObject?
    {
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Coalesce, or a multi-event save is read mid-rewrite. Up to a limit:
            // the folder's events count too, and steady writes beside the file
            // would otherwise put the reload off for as long as they last.
            let now = ProcessInfo.processInfo.systemUptime
            if self.pendingReload != nil, now - self.pendingReloadSince >= Self.longestReloadDelay { return }
            if self.pendingReload == nil { self.pendingReloadSince = now }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingReload = nil
                self?.reloadFromWatcher()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func reloadFromWatcher() {
        // Re-watch before reading: an atomic save replaced the inode. The
        // read happens off the main actor after the replacement is watching.
        startWatching()
    }
}
