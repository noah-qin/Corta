import Foundation
import Testing

@testable import Corta

/// M6.1 — the config file format. The file is the single source of truth,
/// so what these assert is that a value survives the round trip out to text
/// and back, and that a broken file still starts a terminal.
struct ConfigurationTests {
    @Test("a new window defaults to a 120 by 30 grid")
    func defaultWindowGrid() {
        let configuration = Configuration()
        #expect(configuration.columns == 120)
        #expect(configuration.rows == 30)
    }

    @Test("a written configuration parses back to itself")
    func roundTrip() {
        var configuration = Configuration()
        configuration.fontFamily = "Menlo"
        configuration.fontSize = 15
        configuration.theme = "solarized"
        configuration.appearance = .dark
        configuration.scrollbackLines = 4242
        configuration.commandHistoryLimit = 128
        configuration.bell = .muted
        configuration.notifyOnLongTask = true
        configuration.notificationThreshold = 90

        let (parsed, unknown) = Configuration.parse(configuration.serialized())
        #expect(parsed == configuration)
        #expect(unknown.isEmpty)
    }

    @Test("comments, blank lines and stray whitespace are ignored")
    func toleratesFormatting() {
        let text = """
            # a comment
              font-size   =   14    # trailing comment

            theme=mono
            """
        let (parsed, _) = Configuration.parse(text)
        #expect(parsed.fontSize == 14)
        #expect(parsed.theme == "mono")
    }

    /// A typo in one setting must not cost the user every other setting, and
    /// the terminal has to start regardless.
    @Test("an unparseable line does not take the rest of the file with it")
    func skipsBrokenLines() {
        let text = """
            font-size = not-a-number
            = orphaned
            theme = solarized
            """
        let (parsed, _) = Configuration.parse(text)
        #expect(parsed.fontSize == Configuration().fontSize)
        #expect(parsed.theme == "solarized")
    }

    @Test("a value outside the supported range is clamped, not rejected")
    func clampsOutOfRangeValues() {
        let (tiny, _) = Configuration.parse("font-size = 2")
        #expect(tiny.fontSize == 8)
        let (huge, _) = Configuration.parse("font-size = 400")
        #expect(huge.fontSize == 64)
        let (negative, _) = Configuration.parse("scrollback-lines = -5")
        #expect(negative.scrollbackLines == 0)
        let (hugeHistory, _) = Configuration.parse("command-history-limit = 999999")
        #expect(hugeHistory.commandHistoryLimit == 10_000)
        let (negativeHistory, _) = Configuration.parse("command-history-limit = -5")
        #expect(negativeHistory.commandHistoryLimit == 0)
    }

    /// The name is kept verbatim and resolved when it is *used*, not when it
    /// is parsed: a custom theme (M7.6) may be defined further down the same
    /// file, so a parse-time existence check would reject every theme the
    /// file itself declares. `AppearanceController` falls back to the default
    /// for a name nothing defines.
    @Test("a theme name is kept as written and resolved on use")
    func unknownThemeFallsBackWhenResolved() {
        let (parsed, _) = Configuration.parse("theme = does-not-exist")
        #expect(parsed.theme == "does-not-exist")
        #expect(Theme.named(parsed.theme, in: parsed) == nil)
    }

    @Test("an empty theme name falls back to the default")
    func emptyThemeFallsBack() {
        let (parsed, _) = Configuration.parse("theme = ")
        #expect(parsed.theme == Theme.corta.name)
    }

    /// A config written by a newer Corta has to survive a round trip through
    /// an older one, or upgrading and downgrading silently loses settings.
    @Test("keys from another version are preserved on write")
    func preservesUnknownKeys() {
        let (parsed, unknown) = Configuration.parse("theme = mono\nfuture-setting = 7\n")
        #expect(unknown.count == 1)
        #expect(unknown[0].0 == "future-setting")
        let written = parsed.serialized(preserving: unknown)
        #expect(written.contains("future-setting = 7"))
    }

    @Test("booleans accept the spellings a hand-editor would use")
    func booleanSpellings() {
        for value in ["true", "yes", "on", "1"] {
            let (parsed, _) = Configuration.parse("notify-on-long-task = \(value)")
            #expect(parsed.notifyOnLongTask, "\(value) should read as true")
        }
        for value in ["false", "no", "off", "0", "nonsense"] {
            let (parsed, _) = Configuration.parse("notify-on-long-task = \(value)")
            #expect(!parsed.notifyOnLongTask, "\(value) should read as false")
        }
    }

    /// U06 — a value Corta cannot parse at all is not silently canonicalised
    /// into the default on the next write: the runtime falls back to the
    /// default, and the original line survives untouched so the user can see
    /// and fix the typo.
    @Test("a malformed value falls back to the default and keeps its line")
    func malformedValueFallsBackAndIsPreserved() {
        let text = """
            font-size = banana
            bell = siren
            copy-on-select = maybe
            scrollback-lines = 42
            """
        let (parsed, unknown) = Configuration.parse(text)
        let defaults = Configuration()
        #expect(parsed.fontSize == defaults.fontSize)
        #expect(parsed.bell == defaults.bell)
        #expect(parsed.copyOnSelect == defaults.copyOnSelect)
        // A neighbouring well-formed value is not taken down with them.
        #expect(parsed.scrollbackLines == 42)
        #expect(unknown.count == 3)
        let written = parsed.serialized(preserving: unknown)
        #expect(written.contains("font-size = banana"))
        #expect(written.contains("bell = siren"))
        #expect(written.contains("copy-on-select = maybe"))
    }

    /// The other half of the malformed-value rule: a value that parses but
    /// lies outside the supported range is still *recognised* — clamped and
    /// rewritten in canonical form, not preserved verbatim.
    @Test("a clamped value is recognised, not preserved verbatim")
    func clampedValueIsRecognised() {
        let (parsed, unknown) = Configuration.parse("font-size = 400")
        #expect(parsed.fontSize == 64)
        #expect(unknown.isEmpty)
    }
}

/// M6.2 and M6.13 — the theme tables themselves.
///
/// Over `Theme.known`, not `Theme.builtIn`: only one theme is *offered* in
/// the UI, but the others stay defined and stay reachable by name — a config
/// file that already selects one, or inherits from one, must still get a
/// complete theme back.
struct ThemeTests {
    @Test("every known theme has both variants fully populated")
    func themesAreComplete() {
        for theme in Theme.known {
            for variant in [theme.dark, theme.light] {
                #expect(variant.ansi.count == 16, "\(theme.name) needs all sixteen ANSI colours")
            }
        }
    }

    @Test("a theme's two variants differ in luminance the way their names say")
    func darkIsDarkerThanLight() {
        for theme in Theme.known {
            let dark = theme.dark.background
            let light = theme.light.background
            #expect(
                dark.x + dark.y + dark.z < light.x + light.y + light.z,
                "\(theme.name)'s dark background must be darker than its light one")
        }
    }

    @Test("theme names are unique and resolvable")
    func namesResolve() {
        var seen = Set<String>()
        for theme in Theme.known {
            #expect(seen.insert(theme.name).inserted, "duplicate theme name \(theme.name)")
            #expect(Theme.named(theme.name)?.name == theme.name)
        }
        #expect(Theme.named("no-such-theme") == nil)
    }
}

/// U06 — the store against a real file, in a temporary directory so no test
/// ever touches the user's actual config. Each test gets a fresh suite
/// instance, hence a fresh directory; the scenarios are the file's whole
/// life cycle: absent at launch, created, replaced, deleted, malformed, and
/// raced between the settings page and an editor.
@MainActor
@Suite(.serialized)
struct ConfigurationStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-config-tests-\(UUID().uuidString)")
    private var file: URL { directory.appendingPathComponent("config") }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The watcher coalesces over 0.1s and reports on the main queue, so a
    /// change is expected well inside a second; the bound is only for a
    /// loaded CI machine.
    @MainActor
    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("absent at launch: a missing file means the defaults, not an error")
    func absentAtLaunchMeansDefaults() {
        defer { removeDirectory() }
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration == Configuration())
        #expect(store.lastWriteError == nil)
    }

    @Test("a file created after launch is picked up, even when its directory did not exist")
    func externalCreationIsPickedUp() async throws {
        defer { removeDirectory() }
        // Neither the file nor its directory exists yet, so this also
        // exercises the ancestor-directory watch: the store must notice the
        // directory appearing and re-point itself before reading the file.
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration == Configuration())
        try writeFile("font-size = 20\n")
        #expect(await waitUpTo(5) { store.configuration.fontSize == 20 })
    }

    @Test("deleting the file restores the defaults")
    func externalDeletionRestoresDefaults() async throws {
        defer { removeDirectory() }
        try writeFile("font-size = 20\n")
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.fontSize == 20)
        try FileManager.default.removeItem(at: file)
        #expect(await waitUpTo(5) { store.configuration == Configuration() })
    }

    @Test("an editor's atomic replacement is picked up")
    func atomicReplacementIsPickedUp() async throws {
        defer { removeDirectory() }
        try writeFile("font-size = 20\n")
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.fontSize == 20)
        // The save every modern editor performs: a temporary file renamed
        // over the target, which the old inode's watcher sees only as a
        // delete.
        try "font-size = 24\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(await waitUpTo(5) { store.configuration.fontSize == 24 })
    }

    @Test("an external edit posts didChange so panes re-read the store")
    func externalEditPostsDidChange() async throws {
        defer { removeDirectory() }
        let store = ConfigurationStore(fileURL: file)
        let counter = ChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: ConfigurationStore.didChange, object: nil, queue: .main
        ) { _ in counter.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try writeFile("font-size = 20\n")
        #expect(await waitUpTo(5) { store.configuration.fontSize == 20 })
        #expect(counter.count > 0)
    }

    @Test("malformed values fall back to defaults and the file text survives the next write")
    func malformedValuesSurviveAWrite() async throws {
        defer { removeDirectory() }
        try writeFile("font-size = banana\nscrollback-lines = 42\n")
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.fontSize == Configuration().fontSize)
        #expect(store.configuration.scrollbackLines == 42)
        // A settings-page write rewrites the file; the malformed line must
        // come through it verbatim.
        #expect(store.update { $0.bell = .audible })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("font-size = banana"))
        #expect(store.configuration.fontSize == Configuration().fontSize)
    }

    @Test("an editor save landing right after a settings write is not swallowed")
    func editorSaveRacingSettingsWriteWins() async throws {
        defer { removeDirectory() }
        let store = ConfigurationStore(fileURL: file)
        #expect(store.update { $0.fontSize = 20 })
        // Immediately after the store's own write — inside what used to be
        // the write-suppression window — an editor replaces the file. The
        // file is the source of truth, so this edit must be seen.
        try writeFile("font-size = 33\n")
        #expect(await waitUpTo(5) { store.configuration.fontSize == 33 })
    }

    /// Mutated from the notification closure (which is `@Sendable` but, like
    /// everything else here, runs on the main thread).
    private final class ChangeCounter: @unchecked Sendable {
        var count = 0
    }
}
