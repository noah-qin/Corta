import Foundation
import Testing

@testable import CortaTerminal

/// A child with no locale runs in the C locale, where zsh's line editor
/// handles input one byte at a time: typing CJK or an emoji produced
/// isolated continuation bytes on screen instead of the character.
@Suite("Child locale") struct LocaleEnvironmentTests {
    @Test func aChildWithNoLocaleGetsAUTF8One() {
        let result = ChildEnvironment.sanitized(inheriting: ["PATH": "/usr/bin"])
        #expect(result["LANG"]?.hasSuffix(".UTF-8") == true)
    }

    @Test func aLocaleTheUserSetIsLeftAlone() {
        for existing in ["LANG", "LC_ALL", "LC_CTYPE"] {
            let result = ChildEnvironment.sanitized(inheriting: [existing: "fr_FR.ISO8859-1"])
            #expect(result["LANG"] != ChildEnvironment.utf8Locale)
        }
    }

    @Test func theLocaleNameIsAWellFormedPair() {
        // "en" is a language, not a locale name; only language_REGION names
        // a file under /usr/share/locale.
        #expect(ChildEnvironment.utf8Locale.contains("_"))
        #expect(ChildEnvironment.utf8Locale.hasSuffix(".UTF-8"))
    }

    /// The end of the chain: a real spawned child reports the variable.
    @Test func aSpawnedChildSeesTheLocale() throws {
        let session = try TerminalSession(
            // Leave room for the host's complete environment. Adding a
            // legitimate variable such as COLORTERM must not scroll LANG
            // out of the fixture before the assertion can observe it.
            executable: "/usr/bin/env", size: TerminalSize(rows: 64, columns: 100))
        defer { session.stop() }
        var dump = ""
        for _ in 0..<3000 {
            dump = session.snapshot().dump()
            if dump.contains("LANG=") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(dump.contains("LANG="))
        #expect(dump.contains(".UTF-8"))
    }
}
