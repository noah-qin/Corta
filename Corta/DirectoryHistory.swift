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

/// Ranks directories the shell actually visited, for the directory
/// switcher. Built only from OSC 7 reports, already host-filtered
/// (`Performer+OSC.swift`), so remote directories never enter it. A plain
/// value: `DirectoryHistoryStore` owns the instance and the file.
struct DirectoryHistory: Equatable {
    struct Entry: Equatable, Codable {
        var path: String
        var visitCount: Int
        var lastVisit: Date
        var isFavorite: Bool
    }

    var entries: [String: Entry] = [:]

    init() {}
    /// A loaded file is held to the limit too: one written before it, or by
    /// hand, may be longer.
    init(entries: [Entry], now: Date = Date()) {
        for entry in entries { self.entries[entry.path] = entry }
        enforceLimit(now: now)
    }

    /// Favorites first, then frecency (visits fading with time); ties broken
    /// by path, so the order is deterministic.
    func ranked(now: Date = Date()) -> [Entry] {
        entries.values.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
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

    /// Directories kept beyond the favourites. The paths are child-reported
    /// (OSC 7, never checked to exist), so output that reports a fresh one
    /// per prompt would otherwise grow the file, and every save's encode,
    /// without bound — and fill the switcher with them.
    static let maximumEntries = 1_000

    /// Records a visit; ignores an empty path. Past `maximumEntries`, the
    /// lowest-ranked directories that are not favourites go — never the one
    /// just visited.
    mutating func record(_ path: String, at date: Date = Date()) {
        guard !path.isEmpty else { return }
        if var entry = entries[path] {
            entry.visitCount += 1
            entry.lastVisit = date
            entries[path] = entry
        } else {
            entries[path] = Entry(path: path, visitCount: 1, lastVisit: date, isFavorite: false)
            enforceLimit(now: date, keeping: path)
        }
    }

    /// At most `maximumEntries` ordinary entries; favourites never count.
    private mutating func enforceLimit(now: Date, keeping kept: String? = nil) {
        let ordinary = entries.values.filter { !$0.isFavorite }
        let excess = ordinary.count - Self.maximumEntries
        guard excess > 0 else { return }
        let lowestFirst = ordinary.filter { $0.path != kept }.sorted { a, b in
            let scoreA = Self.frecency(a, now: now)
            let scoreB = Self.frecency(b, now: now)
            if scoreA != scoreB { return scoreA < scoreB }
            return a.path > b.path
        }
        for entry in lowestFirst.prefix(excess) { entries[entry.path] = nil }
    }

    /// Pins or unpins; pinning an unvisited path creates a zero-score entry.
    mutating func setFavorite(_ isFavorite: Bool, for path: String) {
        if var entry = entries[path] {
            entry.isFavorite = isFavorite
            entries[path] = entry
            // An unpinned directory counts again.
            if !isFavorite { enforceLimit(now: Date(), keeping: path) }
        } else if isFavorite {
            entries[path] = Entry(path: path, visitCount: 0, lastVisit: .distantPast, isFavorite: true)
        }
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
    static let shared = DirectoryHistoryStore(fileURL: DirectoryHistoryStore.defaultFileURL)

    private(set) var history = DirectoryHistory()
    /// Injected so tests use a temporary file.
    let fileURL: URL

    /// A burst of commands is one write.
    static let defaultSaveDelay: TimeInterval = 0.5

    /// Injected: a test asserting the write hasn't happened yet can't race a
    /// real timer, so it passes an unreachable delay and calls `flush()`.
    let saveDelay: TimeInterval

    private var pendingSave: DispatchWorkItem?
    /// Serial, so an in-flight write can't undo a clear.
    private let writeQueue = DispatchQueue(label: "Corta.DirectoryHistoryStore", qos: .utility)

    static var defaultFileURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("directory-history.json")
    }

    init(fileURL: URL, saveDelay: TimeInterval = DirectoryHistoryStore.defaultSaveDelay) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        load()
    }

    /// Records and schedules a save; a no-op when the setting is off.
    func record(_ path: String) {
        guard ConfigurationStore.shared.configuration.directoryHistory else { return }
        history.record(path)
        scheduleSave()
    }

    func setFavorite(_ isFavorite: Bool, for path: String) {
        history.setFavorite(isFavorite, for: path)
        scheduleSave()
    }

    /// Removes the history and its file, after any in-flight write.
    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        history.clear()
        let fileURL = fileURL
        writeQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Writes a pending save now and waits, for quit.
    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        save()
        writeQueue.sync {}
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            // An unknown newer version loads nothing rather than guess.
            guard persisted.version <= Persisted.currentVersion else { return }
            history = DirectoryHistory(entries: persisted.entries)
            return
        }
        // Files from before the wrapper are a bare array.
        guard let entries = try? JSONDecoder().decode([DirectoryHistory.Entry].self, from: data)
        else { return }
        history = DirectoryHistory(entries: entries)
    }

    /// Snapshots on the main actor; encodes and writes on `writeQueue`.
    private func save() {
        let persisted = Persisted(
            version: Persisted.currentVersion, entries: Array(history.entries.values))
        let fileURL = fileURL
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(persisted) else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
