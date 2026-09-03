import Testing

@testable import Corta

/// M6.1 — the config file format. The file is the single source of truth,
/// so what these assert is that a value survives the round trip out to text
/// and back, and that a broken file still starts a terminal.
struct ConfigurationTests {
    @Test("a written configuration parses back to itself")
    func roundTrip() {
        var configuration = Configuration()
        configuration.fontFamily = "Menlo"
        configuration.fontSize = 15
        configuration.theme = "solarized"
        configuration.appearance = .dark
        configuration.scrollbackLines = 4242
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
    }

    @Test("a theme that does not exist falls back to the default")
    func unknownThemeFallsBack() {
        let (parsed, _) = Configuration.parse("theme = does-not-exist")
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
}

/// M6.2 and M6.13 — the theme tables themselves.
struct ThemeTests {
    @Test("every built-in theme has both variants fully populated")
    func themesAreComplete() {
        for theme in Theme.builtIn {
            for variant in [theme.dark, theme.light] {
                #expect(variant.ansi.count == 16, "\(theme.name) needs all sixteen ANSI colours")
            }
        }
    }

    @Test("a theme's two variants differ in luminance the way their names say")
    func darkIsDarkerThanLight() {
        for theme in Theme.builtIn {
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
        for theme in Theme.builtIn {
            #expect(seen.insert(theme.name).inserted, "duplicate theme name \(theme.name)")
            #expect(Theme.named(theme.name)?.name == theme.name)
        }
        #expect(Theme.named("no-such-theme") == nil)
    }
}
