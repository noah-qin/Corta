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

import Foundation
import Synchronization

/// Ranks directories the shell actually visited, for the directory
/// switcher. Built only from OSC 7 reports, already host-filtered
/// (`Performer+OSC.swift`), so remote directories never enter it. A plain
/// value: `DirectoryHistoryStore` owns the instance and the file.
struct DirectoryHistory: Equatable {
    struct Entry: Equatable, Codable {
        var path: String
        var visitCount: Int
        var lastVisit: Date
    }

    var entries: [String: Entry] = [:]

    init() {}
    /// A loaded file is held to the limit too: one written before it, or by
    /// hand, may be longer.
    init(entries: [Entry], now: Date = Date()) {
        for entry in entries { self.entries[entry.path] = entry }
        enforceLimit(now: now)
    }

    /// By frecency (visits fading with time); ties broken by path, so the
    /// order is deterministic.
    func ranked(now: Date = Date()) -> [Entry] {
        entries.values.sorted { a, b in
            let scoreA = Self.frecency(a, now: now)
            let scoreB = Self.frecency(b, now: now)
            if scoreA != scoreB { return scoreA > scoreB }
            return a.path < b.path
        }
    }

    /// A visit's weight halves in three days: the switcher answers "where was
    /// I this week".
    private static let halfLife: TimeInterval = 3 * 24 * 3600

    private static func frecency(_ entry: Entry, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(entry.lastVisit))
        return Double(entry.visitCount) * pow(0.5, age / halfLife)
    }

    /// Directories kept. The paths are child-reported
    /// (OSC 7, never checked to exist), so output that reports a fresh one
    /// per prompt would otherwise grow the file, and every save's encode,
    /// without bound — and fill the switcher with them.
    static let maximumEntries = 1_000

    /// Records a visit; ignores an empty path. Past `maximumEntries`, the
    /// lowest-ranked directories go — never the one just visited.
    mutating func record(_ path: String, at date: Date = Date()) {
        guard !path.isEmpty else { return }
        if var entry = entries[path] {
            entry.visitCount += 1
            entry.lastVisit = date
            entries[path] = entry
        } else {
            entries[path] = Entry(path: path, visitCount: 1, lastVisit: date)
            enforceLimit(now: date, keeping: path)
        }
    }

    /// At most `maximumEntries` entries.
    private mutating func enforceLimit(now: Date, keeping kept: String? = nil) {
        let excess = entries.count - Self.maximumEntries
        guard excess > 0 else { return }
        let lowestFirst = entries.values.filter { $0.path != kept }.sorted { a, b in
            let scoreA = Self.frecency(a, now: now)
            let scoreB = Self.frecency(b, now: now)
            if scoreA != scoreB { return scoreA < scoreB }
            return a.path > b.path
        }
        for entry in lowestFirst.prefix(excess) { entries[entry.path] = nil }
    }

    mutating func clear() { entries.removeAll() }

    /// Fuzzy subsequence filter over `ranked(now:)`; an empty query is the
    /// same list unfiltered.
    func matching(_ query: String, now: Date = Date()) -> [Entry] {
        guard !query.isEmpty else { return ranked(now: now) }
        let needle = query.lowercased()
        return
            ranked(now: now)
            .compactMap { entry -> (Entry, Int)? in
                guard let score = Self.fuzzyScore(needle: needle, haystack: entry.path.lowercased())
                else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// In-order subsequence match, scoring consecutive and early matches
    /// higher.
    private static func fuzzyScore(needle: String, haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        var score = 0
        var consecutiveBonus = 0
        var haystackIndex = haystack.startIndex
        for needleChar in needle {
            guard
                let matchIndex = haystack[haystackIndex...].firstIndex(where: { $0 == needleChar })
            else { return nil }
            let gap = haystack.distance(from: haystackIndex, to: matchIndex)
            consecutiveBonus = gap == 0 ? consecutiveBonus + 1 : 0
            score += 10 - min(gap, 9) + consecutiveBonus
            haystackIndex = haystack.index(after: matchIndex)
        }
        return score
    }

    /// The nearest ancestor containing `.git`; deliberately narrow, since a
    /// wrong guess moves the user somewhere unasked.
    nonisolated static func projectRoot(for path: String, fileManager: FileManager = .default) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let marker = url.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: marker, isDirectory: &isDirectory) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// Persists `DirectoryHistory` in Application Support: state, not a
/// setting (as `SessionRestore`). `directory-history = false` stops reads
/// and writes.
///
/// Writes are debounced and off the main thread: `record` runs from the
/// render path, and a JSON encode plus atomic write in the vsync callback
/// per command was too much. `flush()` writes what's pending at quit.
@MainActor
final class DirectoryHistoryStore {
    /// Read in the background: the first visit, or the first window, no
    /// longer waits on the file (`loadsInBackground`).
    static let shared = DirectoryHistoryStore(fileURL: DirectoryHistoryStore.defaultFileURL, loadsInBackground: true)

    private(set) var history = DirectoryHistory()
    /// Injected so tests use a temporary file.
    let fileURL: URL

    /// A burst of commands is one write.
    static let defaultSaveDelay: TimeInterval = 0.5

    /// Injected: a test asserting the write hasn't happened yet can't race a
    /// real timer, so it passes an unreachable delay and calls `flush()`.
    let saveDelay: TimeInterval

    private var pendingSave: DispatchWorkItem?
    /// The file on disk is from a newer Corta; it is left alone.
    private(set) var preservesNewerFile = false
    private var preservesUnreadableFile = false
    private(set) var persistenceError: (any Error)?
    private var persistenceGeneration = 0
    /// Serial, so an in-flight write can't undo a clear.
    private let writeQueue: DispatchQueue
    private var clearing: Clearing?

    private struct Clearing {
        let deletion: HistoryFileDeletion
        var history = DirectoryHistory()
        let wasPending: Bool
    }

    var isClearing: Bool { clearing != nil }

    static var defaultFileURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("directory-history.json")
    }

    /// The file's contents, read on `writeQueue` while `loadsInBackground`
    /// has not delivered them yet.
    private var pendingLoad: PendingLoad<LoadOutcome>?
    /// Visits recorded before the file was read, replayed onto it: neither
    /// lost nor saved over a file not yet seen.
    private var recordedBeforeLoad: [(path: String, date: Date)] = []
    var isLoaded: Bool { pendingLoad == nil }

    /// `loadsInBackground`: read and decoded on `writeQueue`, and applied on
    /// the main actor when done — or at once by whatever needs it first
    /// (`clear`, `flush`). Unset, read here, as tests rely on.
    init(
        fileURL: URL, saveDelay: TimeInterval = DirectoryHistoryStore.defaultSaveDelay,
        writeQueue: DispatchQueue = DispatchQueue(label: "Corta.DirectoryHistoryStore", qos: .utility),
        loadsInBackground: Bool = false
    ) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.writeQueue = writeQueue
        guard loadsInBackground else {
            apply(Self.read(fileURL))
            return
        }
        let pending = PendingLoad<LoadOutcome>()
        pendingLoad = pending
        writeQueue.async { [weak self] in
            pending.deliver(Self.read(fileURL))
            Task { @MainActor [weak self] in self?.applyPendingLoad() }
        }
    }

    /// The background read's answer, once; no-op when there is none yet
    /// or it was already applied.
    private func applyPendingLoad() {
        guard let pending = pendingLoad, let outcome = pending.take() else { return }
        pendingLoad = nil
        apply(outcome)
        for visit in recordedBeforeLoad { history.record(visit.path, at: visit.date) }
        let owed = !recordedBeforeLoad.isEmpty
        recordedBeforeLoad.removeAll()
        if owed { scheduleSave() }
    }

    /// Waits for the background read, at most until `deadline`, and applies it.
    private func finishLoading(until deadline: DispatchTime) {
        guard let pending = pendingLoad else { return }
        pending.wait(until: deadline)
        applyPendingLoad()
    }

    /// Records and schedules a save; a no-op when the setting is off.
    func record(_ path: String) {
        guard ConfigurationStore.shared.configuration.directoryHistory else { return }
        guard isLoaded else {
            let now = Date()
            history.record(path, at: now)
            recordedBeforeLoad.append((path, now))
            return
        }
        history.record(path)
        if isClearing {
            clearing?.history.record(path)
        } else {
            scheduleSave()
        }
    }

    /// Removes the history and its file, after any in-flight write.
    func clear() async {
        if !isLoaded {
            await withCheckedContinuation { continuation in writeQueue.async { continuation.resume() } }
            applyPendingLoad()
        }
        guard !preservesNewerFile, !preservesUnreadableFile, !isClearing else { return }
        let deletion = HistoryFileDeletion(fileURL, on: writeQueue)
        clearing = Clearing(deletion: deletion, wasPending: pendingSave != nil)
        pendingSave?.cancel()
        pendingSave = nil
        persistenceGeneration += 1
        await deletion.wait()
        finishClear(deletion)
    }

    private func finishClear(_ deletion: HistoryFileDeletion) {
        guard let clearing, clearing.deletion === deletion, let result = deletion.result else { return }
        self.clearing = nil
        switch result {
        case .success:
            history = clearing.history
            persistenceError = nil
            if !history.entries.isEmpty { scheduleSave() }
        case .failure(let error):
            persistenceError = error
            if clearing.wasPending || !clearing.history.entries.isEmpty { save(reportSuccess: false) }
        }
    }

    /// Writes a pending save now and waits, for quit.
    func flush() {
        let group = DispatchGroup()
        let deadline = DispatchTime.now() + .seconds(1)
        flush(into: group, deadline: deadline)
        _ = group.wait(timeout: deadline)
    }

    /// `flush` without its wait: the save is queued and `group` is left
    /// when it is written, so a quit can wait for every store at once
    /// under one deadline.
    func flush(into group: DispatchGroup, deadline: DispatchTime) {
        finishLoading(until: deadline)
        if let deletion = clearing?.deletion {
            deletion.wait(until: deadline)
            finishClear(deletion)
        }
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            save()
        }
        group.enter()
        writeQueue.async { group.leave() }
    }

    /// A save is scheduled and has not run.
    var hasPendingSave: Bool { pendingSave != nil }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.save()
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: item)
    }

    /// Versioned, so a future change can migrate instead of losing the file.
    private nonisolated struct Persisted: Codable {
        static let currentVersion = 1
        var version: Int
        var entries: [DirectoryHistory.Entry]
    }

    private nonisolated struct VersionProbe: Decodable {
        var version: Int
    }

    /// What reading the file found; read anywhere, applied on the main actor.
    enum LoadOutcome: Sendable {
        case nothing
        case unreadable(any Error)
        case newer
        case entries([DirectoryHistory.Entry])
    }

    nonisolated static func read(_ fileURL: URL) -> LoadOutcome {
        let data: Data
        do {
            guard let loaded = try PrivateFile.readBounded(fileURL) else { return .nothing }
            data = loaded
        } catch {
            return .unreadable(error)
        }
        // The version alone first: a newer version is usually a new shape,
        // which the full decode below would fail and then overwrite.
        if let version = try? JSONDecoder().decode(VersionProbe.self, from: data).version,
            version > Persisted.currentVersion
        {
            return .newer
        }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            // An unknown newer version loads nothing rather than guess, and
            // is not overwritten: this build's save would replace it with
            // what little this run records.
            guard persisted.version <= Persisted.currentVersion else { return .newer }
            return .entries(persisted.entries)
        }
        // Files from before the wrapper are a bare array.
        guard let entries = try? JSONDecoder().decode([DirectoryHistory.Entry].self, from: data)
        else { return .nothing }
        return .entries(entries)
    }

    private func apply(_ outcome: LoadOutcome) {
        switch outcome {
        case .nothing:
            history = DirectoryHistory()
        case .unreadable(let error):
            preservesUnreadableFile = true
            persistenceError = error
        case .newer:
            preservesNewerFile = true
        case .entries(let entries):
            history = DirectoryHistory(entries: entries)
        }
    }

    /// Snapshots on the main actor; encodes and writes on `writeQueue`.
    private func save(reportSuccess: Bool = true) {
        guard isLoaded, !preservesNewerFile, !preservesUnreadableFile else { return }
        let persisted = Persisted(
            version: Persisted.currentVersion, entries: Array(history.entries.values))
        let fileURL = fileURL
        persistenceGeneration += 1
        let generation = persistenceGeneration
        writeQueue.async { [weak self] in
            let result = Result {
                try PrivateFile.write(JSONEncoder().encode(persisted), to: fileURL)
            }
            Task { @MainActor [weak self] in
                guard let self, generation == self.persistenceGeneration else { return }
                switch result {
                case .success:
                    if reportSuccess { self.persistenceError = nil }
                case .failure(let error):
                    self.persistenceError = error
                }
            }
        }
    }
}

/// A background read's answer, handed to the main actor once.
nonisolated final class PendingLoad<Outcome: Sendable>: Sendable {
    private let state = Mutex<(outcome: Outcome?, taken: Bool)>((nil, false))
    private let delivered = DispatchSemaphore(value: 0)

    func deliver(_ outcome: Outcome) {
        state.withLock { $0.outcome = outcome }
        delivered.signal()
    }

    /// The answer, the first time it is asked for after it came.
    func take() -> Outcome? {
        state.withLock { state in
            guard !state.taken, let outcome = state.outcome else { return nil }
            state.taken = true
            return outcome
        }
    }

    func wait(until deadline: DispatchTime) {
        if state.withLock({ $0.outcome != nil }) { return }
        if delivered.wait(timeout: deadline) == .success { delivered.signal() }
    }
}
