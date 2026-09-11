import Foundation

/// B08 — ranks the directories a shell has actually visited, so a directory
/// switcher can offer "where you probably want to go" instead of everything
/// under `$HOME`. Built from `OSC 7` reports the same way `CommandRecord` is
/// built from `OSC 133` (`CortaTerminal/CommandRecord.swift`): never guessed
/// from the grid's text, only from what the shell told Corta — and, like
/// that report, already local-host-filtered before it ever reaches here
/// (`Performer+OSC.swift`'s `setWorkingDirectory`), so a directory recorded
/// from a remote session's `OSC 7` never enters this history at all.
///
/// A plain value type, not an actor or a store: `DirectoryHistoryStore` owns
/// the one instance that matters and the file it persists to; this is the
/// ranking and matching logic, testable with no disk and no app around it.
struct DirectoryHistory: Equatable {
    struct Entry: Equatable, Codable {
        var path: String
        var visitCount: Int
        var lastVisit: Date
        var isFavorite: Bool
    }

    var entries: [String: Entry] = [:]

    init() {}
    init(entries: [Entry]) {
        for entry in entries { self.entries[entry.path] = entry }
    }

    /// Ranked: favorites first, then by frecency — visit count that fades
    /// with time, so a directory visited fifty times last year does not
    /// outrank one visited three times this morning. Deterministic: two
    /// calls with the same entries and the same `now` return the same
    /// order, tie-broken by path so the result never depends on
    /// `Dictionary`'s iteration order.
    func ranked(now: Date = Date()) -> [Entry] {
        entries.values.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let scoreA = Self.frecency(a, now: now)
            let scoreB = Self.frecency(b, now: now)
            if scoreA != scoreB { return scoreA > scoreB }
            return a.path < b.path
        }
    }

    /// How long it takes a visit's weight to halve. Three days, not thirty:
    /// the switcher exists to answer "where was I working this week", and a
    /// project abandoned a month ago should stop crowding out this
    /// afternoon's directories well before it falls out of the list
    /// entirely.
    private static let halfLife: TimeInterval = 3 * 24 * 3600

    private static func frecency(_ entry: Entry, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(entry.lastVisit))
        return Double(entry.visitCount) * pow(0.5, age / halfLife)
    }

    /// Records a visit. Empty paths are not a directory — `OSC 7` should
    /// never produce one (`setWorkingDirectory` already rejects an empty
    /// path), but this is cheap insurance against a history entry nothing
    /// could ever show a name for.
    mutating func record(_ path: String, at date: Date = Date()) {
        guard !path.isEmpty else { return }
        if var entry = entries[path] {
            entry.visitCount += 1
            entry.lastVisit = date
            entries[path] = entry
        } else {
            entries[path] = Entry(path: path, visitCount: 1, lastVisit: date, isFavorite: false)
        }
    }

    /// Pins or unpins a path. Pinning a path with no recorded visits (typed
    /// or dragged in directly) creates an entry for it at zero frecency —
    /// favorites sort first regardless, so the zero score never matters
    /// until it is unpinned.
    mutating func setFavorite(_ isFavorite: Bool, for path: String) {
        if var entry = entries[path] {
            entry.isFavorite = isFavorite
            entries[path] = entry
        } else if isFavorite {
            entries[path] = Entry(path: path, visitCount: 0, lastVisit: .distantPast, isFavorite: true)
        }
    }

    mutating func clear() { entries.removeAll() }

    /// A fuzzy subsequence filter over `ranked(now:)`, highest match first.
    /// Empty query returns the base ranking unfiltered — the two are meant
    /// to be the same list before and after the first keystroke, not two
    /// different views.
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

    /// Every character of `needle` must appear in `haystack` in order, not
    /// necessarily contiguous — the standard fuzzy-filename match. Higher
    /// scores a tighter match: consecutive characters and an early,
    /// low-gap match both add more than a distant one, the two signals any
    /// fuzzy file matcher uses to prefer `Projects/corta` over
    /// `Projects/some/other/corta-adjacent/thing` for the query `corta`.
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

    /// The nearest ancestor of `path` that looks like a project root — the
    /// first one, walking up, containing `.git`. Narrow on purpose: this
    /// exists to jump to project roots reliably, not to guess at every build
    /// system's own marker file, and a wrong guess sends a directory change
    /// somewhere the user did not ask for.
    static func projectRoot(for path: String, fileManager: FileManager = .default) -> String? {
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

/// Reads and writes `DirectoryHistory` to disk — Application Support, not
/// the config file, for the reason `SessionRestore` is (`SessionRestore
/// .swift`'s doc comment): this is state Corta maintains from watching
/// `OSC 7`, not a setting a person edits. `directory-history = false` stops
/// it being read *or* written, so turning the feature off leaves nothing
/// behind — B08's "history can be disabled and cleared."
@MainActor
final class DirectoryHistoryStore {
    static let shared = DirectoryHistoryStore(fileURL: DirectoryHistoryStore.defaultFileURL)

    private(set) var history = DirectoryHistory()
    /// Injected so a test can point at a temporary file instead of the
    /// user's real Application Support directory.
    let fileURL: URL

    static var defaultFileURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corta/directory-history.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Records a visit and persists it, unless the setting is off — in
    /// which case this is a no-op rather than a write nobody asked for.
    func record(_ path: String) {
        guard ConfigurationStore.shared.configuration.directoryHistory else { return }
        history.record(path)
        save()
    }

    func setFavorite(_ isFavorite: Bool, for path: String) {
        history.setFavorite(isFavorite, for: path)
        save()
    }

    /// Wipes the in-memory history and the file behind it — not just an
    /// empty write, so nothing is left to reappear if the setting is turned
    /// back on later.
    func clear() {
        history.clear()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONDecoder().decode([DirectoryHistory.Entry].self, from: data)
        else { return }
        history = DirectoryHistory(entries: entries)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(history.entries.values)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
