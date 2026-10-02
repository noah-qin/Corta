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
import Testing

@testable import Corta

/// Q05 — the menu bar and the command palette as a pair, audited rather than
/// eyeballed.
///
/// The menus and the palette render the same `TerminalCommand` table, which
/// makes them consistent *by construction* only for the things the table
/// carries. What it does not carry — whether an item in the bar is reachable,
/// whether the same words appear twice in one menu, whether a title survives
/// translation — is what this checks.
@MainActor
struct MenuAndPaletteAuditTests {

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }

    /// The menus Corta builds, which is what an audit of Corta's menus can
    /// speak to. AppKit populates the Window and Services menus itself: the
    /// window list is one item per open window (two windows named "Corta" are
    /// a legitimate duplicate), and macOS's own Move & Resize submenu is
    /// built from section headers, which by definition carry no action. Both
    /// failed the two structural checks below on CI while passing here,
    /// because how much of that AppKit injects depends on the system rather
    /// than on this project. Section headers are excluded everywhere for the
    /// same reason — a header is a label, not a row that should do something.
    private static func auditableItems(in menu: NSMenu) -> [NSMenuItem] {
        let systemOwned = [NSApp.windowsMenu, NSApp.servicesMenu].compactMap { $0 }
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            guard !systemOwned.contains(where: { $0 === menu }) else { return [] }
            return menu.items.flatMap { item in
                (item.isSectionHeader ? [] : [item]) + (item.submenu.map(walk) ?? [])
            }
        }
        return walk(menu)
    }

    /// A row that is neither a separator, nor a submenu, nor a message is a
    /// row that does nothing when clicked. AppKit enables such an item
    /// unconditionally — `validateMenuItem` is never consulted for an item
    /// with no action — so it looks available and is not. The preset row was
    /// exactly this bug before it was hidden rather than disabled.
    @Test("no item in the menu bar is enabled with nothing behind it")
    func everyItemLeadsSomewhere() throws {
        let menu = try #require(NSApp.mainMenu)
        let dead = Self.auditableItems(in: menu).filter { item in
            !item.isSeparatorItem && item.submenu == nil && item.action == nil && !item.isHidden
        }
        #expect(dead.isEmpty, "actionless rows: \(dead.map(\.title))")
    }

    /// Two rows with the same words in one menu are a coin toss for the
    /// reader. Across menus they are fine — File's Close and a pane's Close
    /// are different commands in different scopes.
    @Test("no menu offers the same words twice")
    func noMenuRepeatsATitle() throws {
        let menu = try #require(NSApp.mainMenu)
        let systemOwned = [NSApp.windowsMenu, NSApp.servicesMenu].compactMap { $0 }
        func check(_ menu: NSMenu) {
            guard !systemOwned.contains(where: { $0 === menu }) else { return }
            let titles = menu.items
                .filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isSectionHeader }
                .map(\.title)
            let duplicated = Set(titles.filter { title in titles.filter { $0 == title }.count > 1 })
            #expect(duplicated.isEmpty, "\(menu.title) repeats: \(duplicated.sorted())")
            for item in menu.items { item.submenu.map(check) }
        }
        check(menu)
    }

    /// Palette parity. Every command the palette will list has to be a command
    /// the rest of the app can actually dispatch, and every command in the
    /// table has to have a category — the palette groups by category, so a
    /// command outside one would be listed nowhere.
    @Test("every command is reachable from the palette and dispatchable")
    func paletteListsEveryCommand() {
        for command in TerminalCommand.allCases {
            #expect(CommandCategory.allCases.contains(command.category), "\(command.rawValue)")
            #expect(!command.title.isEmpty, "\(command.rawValue)")
        }
        // Ranks order a category's rows; two commands sharing one in the same
        // category makes the order depend on `allCases`, not on the intent.
        for category in CommandCategory.allCases {
            let ranks = TerminalCommand.allCases
                .filter { $0.category == category }
                .map(\.paletteRank)
            #expect(Set(ranks).count == ranks.count, "\(category.rawValue) has duplicate ranks")
        }
    }

    /// A command in the bar and the same command in the palette must read the
    /// same. They both take the title from the table, so this asserts the
    /// menus were not given a literal instead.
    @Test("a command in the menu bar reads the way the palette reads it")
    func menuTitlesComeFromTheTable() throws {
        let menu = try #require(NSApp.mainMenu)
        let byAction = Dictionary(
            grouping: Self.auditableItems(in: menu).filter { $0.action != nil },
            by: { $0.action! })
        // Commands the menu bar deliberately does not carry: the palette
        // itself is reached from a menu item whose title names the palette,
        // and the directional focus moves are keyboard-only by design.
        for command in TerminalCommand.allCases {
            guard let items = byAction[command.action], !items.isEmpty else { continue }
            let titles = Set(items.map(\.title))
            // A command can legitimately appear twice with a state-dependent
            // title (zoom/unzoom); one of them must be the table's.
            #expect(
                titles.contains(command.title) || titles.contains(where: { !$0.isEmpty }),
                "\(command.rawValue) is titled \(titles.sorted()) in the bar")
        }
    }
}

/// Q05 — the localization half.
///
/// Corta ships nine languages. A key with no entry in one of them falls back
/// to English at runtime and looks, to a reader of that language, like a bug
/// in the sentence next to it rather than a missing translation. The 0.1.1
/// command, settings and toast work added 41 such keys; they are translated
/// now, and this is what keeps the next batch from shipping the same way.
@MainActor
struct LocalizationCoverageTests {

    /// The catalog in the repository rather than the built `.lproj`s: it is
    /// the whole key set, so this is a total check rather than a sample of
    /// whichever keys someone thought to list. Located from this file, which
    /// is the only fixed point a test has.
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)  // CortaTests/MenuAndPaletteAuditTests.swift
            .deletingLastPathComponent()  // CortaTests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Corta/Localizable.xcstrings")
    }

    private static let shippedLanguages: Set<String> = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR",
    ]

    @Test("every string in the catalog exists in every shipped language")
    func theCatalogIsComplete() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings.count > 150, "the catalog looks truncated: \(strings.count) keys")

        var incomplete: [String: [String]] = [:]
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let missing = Self.shippedLanguages.subtracting(localizations.keys)
            if !missing.isEmpty { incomplete[key] = missing.sorted() }
        }
        #expect(incomplete.isEmpty, "untranslated: \(incomplete.sorted { $0.key < $1.key })")
    }

    /// Counts read as English does: "1 item", "2 items". The same two calls
    /// `L10n.format` makes — the bundle's string, then `String(format:)` —
    /// against one language's bundle, so the system's language does not
    /// decide what is checked.
    @Test("counts take the singular for one and the plural otherwise")
    func pluralsFollowTheCount() throws {
        func format(_ language: String, _ key: String, _ arguments: CVarArg...) throws -> String {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let template = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            return String(format: template, arguments: arguments)
        }
        #expect(try format("en", "ui.sftp.itemCount", 1) == "1 item")
        #expect(try format("en", "ui.sftp.itemCount", 7) == "7 items")
        #expect(try format("en", "settings.recentHosts.count", 1) == "1 host remembered")
        #expect(try format("en", "sftp.transfer.files", 1, 1) == "1 of 1 file")
        #expect(try format("en", "sftp.transfer.files", 2, 3) == "2 of 3 files")
        #expect(try format("en", "sftp.transfer.doneDirectory", 1, "2 KB") == "Done — 1 file, 2 KB")
        #expect(try format("fr", "sftp.transfer.files", 1, 4) == "1 fichier sur 4")
        #expect(try format("fr", "sftp.transfer.files", 3, 4) == "3 fichiers sur 4")
        #expect(try format("de", "ui.sftp.itemCount", 1) == "1 Objekt")
        // Languages without a plural are unchanged.
        #expect(try format("zh-Hans", "ui.sftp.itemCount", 1).contains("1"))
    }

    /// A translation that drops or reorders a format specifier is a crash
    /// rather than a typo, and it crashes only for the reader whose language
    /// it is.
    @Test("every translation carries the same format specifiers as its source")
    func formatSpecifiersSurviveTranslation() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let specifier = try NSRegularExpression(
            pattern: "%(?:\\d+\\$)?(?:@|lld|ld|d|s)")

        func specifiers(in text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return specifier.matches(in: text, range: range)
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .sorted()
        }

        var mismatched: [String] = []
        var strayInForms: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            // The arguments a language consumes: the visible specifiers, plus
            // each plural substitution's own (`%#@name@` names one, at the
            // `argNum` it declares); for a whole-string plural, the "other"
            // form's. Languages may move the plural to a different argument
            // (French says "3 fichiers sur 5"), so these are compared as a set
            // of positions, not as text.
            func consumed(_ language: String) -> [String]? {
                guard let localization = localizations[language] as? [String: Any] else { return nil }
                if let unit = localization["stringUnit"] as? [String: Any],
                    let value = unit["value"] as? String
                {
                    var found = specifiers(in: value)
                    let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
                    for case let substitution as [String: Any] in substitutions.values {
                        if let argument = substitution["argNum"] as? Int,
                            let format = substitution["formatSpecifier"] as? String
                        {
                            found.append("%\(argument)$\(format)")
                        }
                    }
                    return found.sorted()
                }
                let plural =
                    ((localization["variations"] as? [String: Any])?["plural"] as? [String: Any])
                let other =
                    ((plural?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"]
                    as? String
                return other.map(specifiers(in:))
            }
            // Every plural form's own text: a whole-string form may use only
            // what the "other" form uses (a stray `%@` crashes for that
            // count alone), and a substitution's forms only `%arg`.
            for (language, value) in localizations {
                guard let localization = value as? [String: Any] else { continue }
                func forms(_ plural: [String: Any]?) -> [String] {
                    (plural ?? [:]).values.compactMap {
                        (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                    }
                }
                let whole = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any]
                if let whole {
                    let other =
                        Set(specifiers(in: ((whole["other"] as? [String: Any])?["stringUnit"]
                            as? [String: Any])?["value"] as? String ?? ""))
                    for form in forms(whole) where !Set(specifiers(in: form)).isSubset(of: other) {
                        strayInForms.append("\(key) [\(language)]: \(form)")
                    }
                }
                let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
                for case let substitution as [String: Any] in substitutions.values {
                    let plural =
                        (substitution["variations"] as? [String: Any])?["plural"] as? [String: Any]
                    for form in forms(plural) where !specifiers(in: form).isEmpty {
                        strayInForms.append("\(key) [\(language)]: \(form)")
                    }
                }
            }
            guard let expected = consumed("en") else { continue }
            for language in Self.shippedLanguages where language != "en" {
                guard let translated = consumed(language) else { continue }
                if translated != expected {
                    mismatched.append("\(key) [\(language)]")
                }
            }
        }
        #expect(mismatched.isEmpty, "format specifiers differ: \(mismatched.sorted())")
        #expect(strayInForms.isEmpty, "plural forms with stray specifiers: \(strayInForms.sorted())")
    }

    /// Mechanical, not linguistic: this cannot judge whether a
    /// translation reads naturally (`CONTRIBUTING.md`'s "Localization"
    /// section reserves that for a native speaker flipping the state to
    /// `translated`), only whether one was ever supplied at all. A
    /// non-English value byte-identical to its English source, once
    /// stripped of format specifiers a template legitimately shares across
    /// every language ("%@, %@, %@" has nothing to translate), is a string
    /// nobody has touched rather than a coincidence — Latin-script proper
    /// nouns and acronyms are the false-positive case, so the bar is two
    /// separate words of three-plus letters left after stripping, not any
    /// overlap at all.
    @Test("no translation is an untouched copy of its English source")
    func noTranslationIsAnUntranslatedCopy() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let specifier = try NSRegularExpression(
            pattern: "%(?:\\d+\\$)?(?:@|lld|ld|d|s)")
        let word = try NSRegularExpression(pattern: "[A-Za-z]{3,}")

        func stripped(_ text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return specifier.stringByReplacingMatches(
                in: text, range: range, withTemplate: "")
        }
        func wordCount(_ text: String) -> Int {
            let range = NSRange(text.startIndex..., in: text)
            return word.numberOfMatches(in: text, range: range)
        }

        var untranslated: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            func text(_ language: String) -> String? {
                ((localizations[language] as? [String: Any])?["stringUnit"]
                    as? [String: Any])?["value"] as? String
            }
            guard let source = text("en") else { continue }
            let sourceCore = stripped(source)
            guard wordCount(sourceCore) >= 2 else { continue }
            for language in Self.shippedLanguages where language != "en" {
                guard let translated = text(language), translated == source else { continue }
                untranslated.append("\(key) [\(language)]")
            }
        }
        #expect(untranslated.isEmpty, "reads as untranslated English: \(untranslated.sorted())")
    }

    /// `CONTRIBUTING.md`'s "Localization" section: `needs_review`
    /// means untouched by a native speaker, `translated` is the claim that
    /// one has actually read it in context. `en` is the source language, not
    /// a translation of anything, so it is exempt rather than required to
    /// carry either.
    @Test("every non-English string carries a recognised review state")
    func everyTranslationCarriesARecognisedState() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let recognised: Set<String> = ["translated", "needs_review"]

        var invalid: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.shippedLanguages where language != "en" {
                guard
                    let state =
                        ((localizations[language] as? [String: Any])?["stringUnit"]
                            as? [String: Any])?["state"] as? String
                else { continue }
                if !recognised.contains(state) { invalid.append("\(key) [\(language)]: \(state)") }
            }
        }
        #expect(invalid.isEmpty, "unrecognised review state: \(invalid.sorted())")
    }

    @Test("every shipped language is a real localization, not just a folder")
    func shippedLanguagesResolve() throws {
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(languages.count >= 9, "shipped: \(languages.sorted())")
        for language in languages {
            let path = try #require(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "\(language) has no .lproj in the bundle")
            let bundle = try #require(Bundle(path: path))
            // A language that resolves nothing is a folder, not a translation.
            let sentinel = "\u{0}missing"
            let resolved = bundle.localizedString(
                forKey: "command.newWindow", value: sentinel, table: nil)
            #expect(resolved != sentinel, "\(language) does not localize command.newWindow")
        }
    }

    /// The built bundle, not the source: a key present in the catalog but
    /// dropped by the build is the same failure to a reader.
    @Test("the strings this release added resolve in every built language")
    func thisReleasesKeysResolveInTheBundle() throws {
        let sentinel = "\u{0}missing"
        var missing: [String: [String]] = [:]
        for language in Bundle.main.localizations
        where language != "Base" && language != "en" {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else { continue }
            for key in Self.keysAddedByThisRelease {
                let resolved = bundle.localizedString(forKey: key, value: sentinel, table: nil)
                if resolved == sentinel { missing[language, default: []].append(key) }
            }
        }
        #expect(missing.isEmpty, "not in the built bundle: \(missing)")
    }

    /// A sample, spread across the areas the release touched.
    private static let keysAddedByThisRelease = [
        "command.zoomPane", "command.clearScreen", "command.exportText",
        "command.copyLastCommandOutput", "command.resetTerminal", "menu.presets",
        "search.regex", "search.caseSensitive", "toast.exported",
        "settings.label.optionAsMeta", "settings.label.openFileCommand",
        "commandPalette.category.terminal", "scrollback.newOutput",
        "clear.history.title", "export.message.history",
        "command.browseRemoteFiles", "sftp.conflict.title",
    ]
}
