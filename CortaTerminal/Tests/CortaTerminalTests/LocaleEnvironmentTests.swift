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

    /// The name must load, not just look right: `zh-Hans_CN` became
    /// `zh_Hans_CN.UTF-8`, which `setlocale` rejects, and the child ran in C.
    @Test(arguments: [
        ("zh-Hans_CN", "zh_CN.UTF-8"), ("zh-Hant_TW", "zh_TW.UTF-8"),
        ("en_US@rg=cnzzzz", "en_US.UTF-8"), ("fr_FR", "fr_FR.UTF-8"),
        ("ja_JP", "ja_JP.UTF-8"), ("en", "en_US.UTF-8"), ("en_CN", "en_US.UTF-8"),
    ])
    func theLocaleNameLoads(identifier: String, expected: String) {
        let name = ChildEnvironment.utf8Locale(for: Locale(identifier: identifier))
        #expect(name == expected)
        #expect(ChildEnvironment.isAvailableLocale(name))
    }

    @Test func theCurrentLocaleLoads() {
        #expect(ChildEnvironment.isAvailableLocale(ChildEnvironment.utf8Locale))
        #expect(!ChildEnvironment.isAvailableLocale("zh_Hans_CN.UTF-8"))
    }

    /// The end of the chain: a real spawned child reports the variable.
    @Test func aSpawnedChildSeesTheLocale() throws {
        let session = try TerminalSession(
            // Leave room for the host's complete environment. Adding a
            // legitimate variable such as COLORTERM must not scroll LANG
            // out of the fixture before the assertion can observe it.
            executable: "/usr/bin/env", size: TerminalSize(rows: 64, columns: 100))
        defer { session.stop() }
        session.start()
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
