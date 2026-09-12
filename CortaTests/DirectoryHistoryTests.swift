import Foundation
import Testing

@testable import Corta

/// B08 — ranking, favorites, fuzzy matching and project-root detection.
/// Pure logic, no disk and no app: `DirectoryHistoryStoreTests` covers
/// persistence separately.
@MainActor
struct DirectoryHistoryTests {
    @Test("a directory visited more often ranks higher, all else equal")
    func moreVisitsRankHigher() {
        var history = DirectoryHistory()
        let now = Date()
        history.record("/a", at: now)
        history.record("/b", at: now)
        history.record("/b", at: now)
        let ranked = history.ranked(now: now)
        #expect(ranked.map(\.path) == ["/b", "/a"])
    }

    @Test("a more recent visit outranks an old one with the same count")
    func recencyBreaksATie() {
        var history = DirectoryHistory()
        let now = Date()
        history.record("/old", at: now.addingTimeInterval(-10 * 24 * 3600))
        history.record("/recent", at: now)
        let ranked = history.ranked(now: now)
        #expect(ranked.map(\.path) == ["/recent", "/old"])
    }

    @Test("favorites always sort first, regardless of frecency")
    func favoritesSortFirst() {
        var history = DirectoryHistory()
        let now = Date()
        for _ in 0..<10 { history.record("/busy", at: now) }
        history.record("/favorite", at: now.addingTimeInterval(-30 * 24 * 3600))
        history.setFavorite(true, for: "/favorite")
        #expect(history.ranked(now: now).first?.path == "/favorite")
    }

    @Test("unfavoriting returns a directory to its ordinary rank")
    func unfavoritingRemovesTheBoost() {
        var history = DirectoryHistory()
        let now = Date()
        history.record("/a", at: now)
        history.record("/b", at: now)
        history.record("/b", at: now)
        history.setFavorite(true, for: "/a")
        #expect(history.ranked(now: now).first?.path == "/a")
        history.setFavorite(false, for: "/a")
        #expect(history.ranked(now: now).first?.path == "/b")
    }

    @Test("clearing removes every entry")
    func clearingRemovesEverything() {
        var history = DirectoryHistory()
        history.record("/a")
        history.record("/b")
        history.clear()
        #expect(history.ranked().isEmpty)
    }

    @Test("an empty path is never recorded")
    func emptyPathIsIgnored() {
        var history = DirectoryHistory()
        history.record("")
        #expect(history.ranked().isEmpty)
    }

    // MARK: - Fuzzy matching

    @Test("a fuzzy query matches directories by subsequence, case-insensitively")
    func fuzzyQueryMatchesBySubsequence() {
        var history = DirectoryHistory()
        history.record("/Users/noah/Developer/personal/Corta")
        history.record("/Users/noah/Downloads")
        let matches = history.matching("crta").map(\.path)
        #expect(matches == ["/Users/noah/Developer/personal/Corta"])
    }

    @Test("a query matching nothing returns an empty list")
    func nonMatchingQueryReturnsNothing() {
        var history = DirectoryHistory()
        history.record("/Users/noah/Developer")
        #expect(history.matching("zzz").isEmpty)
    }

    @Test("an empty query returns the base ranking")
    func emptyQueryReturnsBaseRanking() {
        var history = DirectoryHistory()
        let now = Date()
        history.record("/a", at: now)
        history.record("/b", at: now)
        history.record("/b", at: now)
        #expect(history.matching("", now: now).map(\.path) == history.ranked(now: now).map(\.path))
    }

    @Test("a tighter, more contiguous match ranks above a looser one")
    func tighterMatchRanksHigher() {
        var history = DirectoryHistory()
        let now = Date()
        // Both contain the subsequence "cta" once; "corta" is a contiguous
        // run and "c-t-a-scattered" is not.
        history.record("/corta", at: now)
        history.record("/c/somewhere/t/deep/a", at: now)
        let matches = history.matching("cta", now: now).map(\.path)
        #expect(matches.first == "/corta")
    }

    // MARK: - Project roots

    @Test("the project root is the nearest ancestor containing .git")
    func projectRootFindsTheNearestGitAncestor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-project-root-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectRoot = directory.appendingPathComponent("project")
        let nested = projectRoot.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(DirectoryHistory.projectRoot(for: nested.path) == projectRoot.path)
    }

    @Test("no .git anywhere in the ancestry means no project root")
    func noGitMeansNoProjectRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-no-project-root-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DirectoryHistory.projectRoot(for: directory.path) == nil)
    }
}

/// B08 — persistence. Every test points at a temporary file, never the
/// user's real Application Support directory.
@MainActor
struct DirectoryHistoryStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-directory-history-tests-\(UUID().uuidString)")
    private var file: URL { directory.appendingPathComponent("directory-history.json") }
    private func removeDirectory() { try? FileManager.default.removeItem(at: directory) }

    @Test("a recorded visit survives a reload from disk")
    func recordedVisitPersists() {
        defer { removeDirectory() }
        let store = DirectoryHistoryStore(fileURL: file)
        store.record("/Users/noah/Developer/personal/Corta")
        let reloaded = DirectoryHistoryStore(fileURL: file)
        #expect(reloaded.history.entries["/Users/noah/Developer/personal/Corta"]?.visitCount == 1)
    }

    @Test("clear removes the file as well as the in-memory history")
    func clearRemovesTheFile() {
        defer { removeDirectory() }
        let store = DirectoryHistoryStore(fileURL: file)
        store.record("/tmp")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.history.entries.isEmpty)
    }

    @Test("an absent file starts with an empty history, not an error")
    func absentFileStartsEmpty() {
        defer { removeDirectory() }
        let store = DirectoryHistoryStore(fileURL: file)
        #expect(store.history.entries.isEmpty)
    }

    // MARK: - Versioning (B09)

    @Test("a pre-B09 file with no version wrapper still loads")
    func bareArrayFileStillLoads() throws {
        defer { removeDirectory() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = DirectoryHistory.Entry(
            path: "/tmp", visitCount: 3, lastVisit: Date(), isFavorite: false)
        try JSONEncoder().encode([entry]).write(to: file)
        let store = DirectoryHistoryStore(fileURL: file)
        #expect(store.history.entries["/tmp"]?.visitCount == 3)
    }

    @Test("a file saved by a future, unrecognized version loads as empty")
    func futureVersionLoadsEmpty() throws {
        defer { removeDirectory() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = Data(#"{"version": 999, "entries": []}"#.utf8)
        try json.write(to: file)
        let store = DirectoryHistoryStore(fileURL: file)
        #expect(store.history.entries.isEmpty)
    }

    @Test("saving writes the current version, and it round-trips")
    func savingWritesCurrentVersion() throws {
        defer { removeDirectory() }
        let store = DirectoryHistoryStore(fileURL: file)
        store.record("/tmp")
        let raw = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        let reloaded = DirectoryHistoryStore(fileURL: file)
        #expect(reloaded.history.entries["/tmp"]?.visitCount == 1)
    }
}
