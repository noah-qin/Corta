import AppKit
import Testing

@testable import Corta

/// U16 — named shell/directory/environment presets, as config-file data.
struct PresetTests {
    @Test("a preset's three parts all parse")
    func fullPreset() {
        let (parsed, unknown) = Configuration.parse(
            """
            preset.api.shell = /bin/bash
            preset.api.arguments = -l -i
            preset.api.directory = /tmp
            preset.api.env.API_ENV = staging
            preset.api.env.NO_COLOR = 1
            """)
        #expect(unknown.isEmpty)
        let preset = try! #require(parsed.presets.first)
        #expect(preset.name == "api")
        #expect(preset.shell == "/bin/bash")
        #expect(preset.arguments == ["-l", "-i"])
        #expect(preset.directory == "/tmp")
        #expect(preset.environment == ["API_ENV": "staging", "NO_COLOR": "1"])
    }

    /// A preset that only sets a directory is a legal preset — requiring all
    /// three fields would mean nobody writes one.
    @Test("a partial preset inherits the rest")
    func partialPreset() {
        let (parsed, _) = Configuration.parse("preset.notes.directory = /tmp")
        let preset = try! #require(parsed.presets.first)
        #expect(preset.shell == nil)
        #expect(preset.arguments.isEmpty)
        #expect(preset.directory == "/tmp")
    }

    /// A name with nothing under it, or a relative shell or directory, is a
    /// typo. It is kept out of the menu rather than offered as something that
    /// will fail at spawn time — the same reason `Spawn` insists on an
    /// absolute path.
    @Test("unusable presets are not offered")
    func unusablePresetsAreDropped() {
        let (empty, _) = Configuration.parse("preset.blank.env. = x")
        #expect(empty.presets.isEmpty)

        let (relativeShell, _) = Configuration.parse("preset.p.shell = bash")
        #expect(relativeShell.presets.isEmpty)

        let (relativeDirectory, _) = Configuration.parse("preset.p.directory = src")
        #expect(relativeDirectory.presets.isEmpty)
    }

    /// A variable name with `=` or NUL in it cannot go into an environment at
    /// all. The *file format* already prevents the first case — a line splits
    /// at its first `=`, so `preset.p.env.A=B = x` parses as the variable `A`
    /// with the value `B = x` — so the guard is asserted directly on the
    /// entry point rather than through a line that cannot express the case.
    @Test("an impossible variable name is refused")
    func badVariableNames() {
        var preset = Preset(name: "p")
        for field in ["env.A=B", "env.", "env.A\u{0}B"] {
            let accepted = preset.apply(field: field, value: "x")
            #expect(!accepted, "\(field) should be refused")
        }
        #expect(preset.environment.isEmpty)
        let ok = preset.apply(field: "env.OK", value: "x")
        #expect(ok)

        // What the file format actually produces for that line.
        let (parsed, _) = Configuration.parse("preset.p.env.A=B = x")
        #expect(parsed.presets.first?.environment == ["A": "B = x"])
    }

    @Test("presets keep the file's order")
    func orderIsPreserved() {
        let (parsed, _) = Configuration.parse(
            """
            preset.zeta.directory = /tmp
            preset.alpha.directory = /var
            """)
        #expect(parsed.presets.map(\.name) == ["zeta", "alpha"])
    }

    @Test("a preset survives a write and re-read")
    func roundTrip() {
        let (parsed, _) = Configuration.parse(
            """
            preset.api.shell = /bin/bash
            preset.api.directory = /tmp
            preset.api.env.API_ENV = staging
            """)
        let (reparsed, unknown) = Configuration.parse(parsed.serialized())
        #expect(unknown.isEmpty)
        #expect(reparsed.presets == parsed.presets)
    }

    /// A key from a newer version is preserved rather than dropped — the same
    /// rule the theme keys follow, so an older Corta writing the file does not
    /// silently delete a newer one's settings.
    @Test("an unknown preset field is preserved")
    func unknownFieldsSurvive() {
        let (_, unknown) = Configuration.parse("preset.p.colour = blue")
        #expect(unknown.contains { $0.0 == "preset.p.colour" })
    }
}

/// The preset menu: present only when presets exist, and describing each one.
@MainActor
struct PresetMenuTests {
    @Test("the summary says what the preset will do") func summary() {
        var preset = Preset(name: "api")
        preset.shell = "/bin/bash"
        preset.directory = "/tmp"
        preset.environment = ["API_ENV": "staging"]
        let summary = AppDelegate.summary(of: preset)
        #expect(summary.contains("/bin/bash"))
        #expect(summary.contains("/tmp"))
        #expect(summary.contains("API_ENV"))
    }

    /// An empty submenu is a promise of a feature the user has not set up.
    @Test("no presets means no rows") func emptyMenuHasNoRows() {
        let delegate = AppDelegate()
        let menu = NSMenu(title: AppDelegate.presetMenuTitle)
        delegate.rebuildPresetMenu(menu)
        #expect(menu.items.isEmpty == ConfigurationStore.shared.configuration.presets.isEmpty)
    }

    /// **Found by running the app, not by a test.** A submenu's parent item
    /// carries no action, so `validateMenuItem` is never asked about it and
    /// AppKit enables it unconditionally: the row sat there enabled, opening
    /// an empty menu. Hiding is the one thing automatic enabling does not
    /// override.
    @Test("the row is hidden, not merely disabled, when there are no presets")
    func emptyPresetRowIsHidden() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        let row = try #require(shell.items.first { $0.title == AppDelegate.presetMenuTitle })
        let hasPresets = !ConfigurationStore.shared.configuration.presets.isEmpty
        #expect(row.isHidden == !hasPresets)
    }
}
