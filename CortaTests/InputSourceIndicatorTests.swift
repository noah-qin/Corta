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
import CortaTerminal
import Testing

@testable import Corta

@MainActor struct InputSourceIndicatorTests {
    @Test func languagesAndPrivateModesAreNotConfusedWithDirectInput() {
        func source(_ id: String, _ lang: String, layout: Bool = false, mode: String? = nil) -> InputSourceState {
            .classify(identifier: id, name: "Example", languages: [lang], isKeyboardLayout: layout, mode: mode)
        }
        #expect(source("com.apple.keylayout.ABC", "en", layout: true).kind == .direct)
        #expect(source("com.apple.inputmethod.SCIM.ITABC", "zh-Hans").badge == "中")
        #expect(source("com.apple.inputmethod.SCIM.ITABC", "zh-Hans").kind == .ime)
        #expect(source("com.apple.inputmethod.TCIM.Zhuyin", "zh-Hant").badge == "中")
        #expect(source("com.apple.inputmethod.Kotoeri.Japanese", "ja").badge == "あ")
        #expect(source("com.apple.inputmethod.Kotoeri.Roman", "ja", mode: "com.apple.inputmethod.Japanese.Roman").kind == .direct)
        #expect(source("com.apple.inputmethod.Korean.2SetKorean", "ko").badge == "한")
        #expect(source("im.rime.inputmethod.Squirrel", "zh-Hans").kind == .unknown)
        #expect(source("com.sogou.inputmethod.sogou", "zh-Hans", mode: "private.ASCII").kind == .unknown)
        #expect(source("com.apple.keylayout.Russian", "ru", layout: true).badge == "RU")
        #expect(source("com.apple.keylayout.Russian", "ru", layout: true).kind == .nonLatinLayout)
    }

    @Test func automaticVisibilityUsesEnabledLanguageScriptsAndIMEType() {
        for language in ["en", "fr", "de", "es", "vi", "sr-Latn"] {
            #expect(!InputSourceVisibility.needsIndicator(languages: [language], isKeyboardLayout: true))
            #expect(InputSourceState.classify(identifier: "layout", name: language,
                languages: [language], isKeyboardLayout: true, mode: nil).kind == .direct)
        }
        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "ru", "ar", "he", "th", "hi", "sr-Cyrl"] {
            #expect(InputSourceVisibility.needsIndicator(languages: [language], isKeyboardLayout: true))
        }
        #expect(InputSourceVisibility.needsIndicator(languages: [], isKeyboardLayout: false))
        #expect(!InputSourceVisibility.needsIndicator(languages: [], isKeyboardLayout: true))
    }

    @Test func enabledSourcesChangesRefreshVisibilityWithoutChangingCurrentSource() {
        let indicator = PaneInputSourceIndicator()
        var enabled = false
        indicator.enabledSourcesProvider = { enabled }
        indicator.sourceProvider = {
            .classify(identifier: "ABC", name: "ABC", languages: ["en"], isKeyboardLayout: true, mode: nil)
        }
        indicator.refreshSource()
        let terminal = Terminal(rows: 4, columns: 30)
        func update(_ mode: Configuration.InputSourceIndicatorMode = .auto) {
            var config = Configuration(); config.inputSourceIndicator = mode
            indicator.update(grid: terminal.grid, hasIntegration: true, promptRow: 0, focused: true,
                scrollOffset: 0, configuration: config, cellSize: CGSize(width: 8, height: 16),
                topInset: 0, compositionRect: nil)
        }
        update(); #expect(indicator.view.isHidden)
        update(.always); #expect(!indicator.view.isHidden)
        enabled = true
        indicator.refreshSource()
        update(); #expect(!indicator.view.isHidden)
        enabled = false
        indicator.refreshSource()
        update(); #expect(indicator.view.isHidden)
    }

    @Test func ordinaryTypingDoesNotRefreshInputContextButCompositionDoes() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        var changes = 0
        view.onInputContextChange = { changes += 1 }
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(changes == 0)
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(changes == 1)
        #expect(view.inputCompositionRect != nil)
        view.unmarkText()
        #expect(changes == 2)
        #expect(view.inputCompositionRect == nil)
    }

    @Test func configurationRoundTripsColorsAndInvalidValuesSurvive() {
        let parsed = Configuration.parse("input-source-indicator = always\ninput-source-indicator-position = prompt\ninput-source-direct-color = #abc\ninput-source-ime-color = #123456")
        #expect(parsed.unknown.isEmpty)
        #expect(parsed.configuration.inputSourceIndicator == .always)
        #expect(parsed.configuration.inputSourceIndicatorPosition == .prompt)
        #expect(Configuration().inputSourceIndicatorPosition == .toolbar)
        #expect(parsed.configuration.inputSourceDirectColor == "#aabbcc")
        #expect(Configuration.parse(parsed.configuration.serialized()).configuration == parsed.configuration)
        let invalid = Configuration.parse("input-source-indicator = sometimes\ninput-source-direct-color = yellow")
        #expect(invalid.unknown.count == 2)
        #expect(invalid.configuration.inputSourceIndicator == .auto)
        #expect(invalid.configuration.inputSourceDirectColor.isEmpty)
    }

    @Test func promptPhaseIncludesMultilinePromptButNotOutputOrPromptRepaint() {
        var terminal = Terminal(rows: 5, columns: 20)
        #expect(!terminal.hasShellIntegration)
        terminal.feed(Array("\u{1b}]133;A\u{7}title\r\n❯ ".utf8))
        #expect(terminal.inputPromptRow == nil)
        terminal.feed(Array("\u{1b}]133;B\u{7}".utf8))
        #expect(terminal.inputPromptRow == 0)
        // B need not be on A's row; a multi-line prompt is still ready.
        #expect(terminal.promptEndPosition == nil)
        terminal.feed(Array("\r\n\u{1b}]133;C\u{7}output".utf8))
        #expect(terminal.inputPromptRow == nil)
        terminal.feed(Array("\u{1b}]133;D;0\u{7}".utf8))
        #expect(terminal.inputPromptRow == nil)
        terminal.feed(Array("\r\n\u{1b}]133;A\u{7}❯ \u{1b}]133;B\u{7}".utf8))
        #expect(terminal.inputPromptRow != nil)
    }

    @Test func longLineMovesDownWithoutFollowingCursorBack() {
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array("❯ ".utf8))
        var placement = InputSourceIndicatorPlacement()
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 0)
        terminal.feed(Array(String(repeating: "x", count: 15).utf8))
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 1)
        terminal.feed(Array("\u{1b}[1G".utf8))
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 1)
        terminal.feed(Array("\u{1b}[1;20Hx\r\n".utf8))
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 1)
        placement.reset()
        #expect(placement.row(grid: terminal.grid, promptRow: 1, badgeColumns: 4) == 1)
    }

    @Test func resizingDiscardsPlacementFromTransientStartupGeometry() {
        var placement = InputSourceIndicatorPlacement()
        var narrow = Terminal(rows: 6, columns: 4)
        narrow.feed(Array("demo ❯ ".utf8))
        #expect(placement.row(grid: narrow.grid, promptRow: 0, badgeColumns: 4)! > 0)
        var settled = Terminal(rows: 18, columns: 60)
        settled.feed(Array("demo ❯ ".utf8))
        #expect(placement.row(grid: settled.grid, promptRow: 0, badgeColumns: 4) == 0)
    }

    @Test func rightPromptWideTextCompositionAndBottomDoNotGetCovered() {
        var terminal = Terminal(rows: 3, columns: 20)
        terminal.feed(Array("\u{1b}[1;19H中\u{1b}[1;3H".utf8))
        var placement = InputSourceIndicatorPlacement()
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 1)
        terminal.feed(Array("\u{1b}[2;17Htext\u{1b}[1;3H".utf8))
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == 2)
        terminal.feed(Array("\u{1b}[3;17Htext\u{1b}[1;3H".utf8))
        #expect(placement.row(grid: terminal.grid, promptRow: 0, badgeColumns: 4) == nil)
        let clean = Terminal(rows: 3, columns: 20)
        placement.reset()
        let composition = CGRect(x: 125, y: 0, width: 60, height: 16)
        #expect(placement.row(grid: clean.grid, promptRow: 0, badgeColumns: 4, compositionRect: composition) == 1)
    }

    @Test func sourceEventsAndVisibilityRespectFocusShellPhaseAndAlternateScreen() throws {
        let indicator = PaneInputSourceIndicator()
        defer { indicator.stop() }
        var reads = 0
        indicator.sourceProvider = {
            reads += 1
            return .classify(identifier: "com.apple.keylayout.ABC", name: "ABC", languages: ["en"], isKeyboardLayout: true, mode: nil)
        }
        indicator.enabledSourcesProvider = { true }
        indicator.start()
        indicator.start()
        #expect(reads == 1)
        var terminal = Terminal(rows: 4, columns: 30)
        func update(integration: Bool = true, prompt: Int? = 0, focus: Bool = true, scroll: Int = 0,
            mode: Configuration.InputSourceIndicatorMode = .auto,
            position: Configuration.InputSourceIndicatorPosition = .prompt) {
            var config = Configuration()
            config.inputSourceIndicator = mode
            config.inputSourceIndicatorPosition = position
            indicator.update(grid: terminal.grid, hasIntegration: integration, promptRow: prompt,
                focused: focus, scrollOffset: scroll, configuration: config,
                cellSize: CGSize(width: 8, height: 16), topInset: 0, compositionRect: nil)
        }
        // On the grid, the badge steps aside for a running command, history
        // and the alternate screen.
        update(); #expect(!indicator.view.isHidden)
        update(prompt: nil); #expect(indicator.view.isHidden)
        update(integration: false, prompt: nil); #expect(!indicator.view.isHidden)
        update(focus: false); #expect(indicator.view.isHidden)
        update(scroll: 1); #expect(indicator.view.isHidden)
        update(mode: .off); #expect(indicator.view.isHidden)
        update(prompt: nil, mode: .always); #expect(!indicator.view.isHidden)
        // In the toolbar it covers nothing, so it stays while Claude Code or
        // any command runs, scrolled back or not.
        update(prompt: nil, position: .toolbar); #expect(!indicator.view.isHidden)
        update(prompt: nil, scroll: 3, position: .toolbar); #expect(!indicator.view.isHidden)
        update(focus: false, position: .toolbar); #expect(indicator.view.isHidden)
        update(mode: .off, position: .toolbar); #expect(indicator.view.isHidden)
        terminal.feed(Array("\u{1b}[?1049h".utf8))
        update(mode: .always); #expect(indicator.view.isHidden)
        update(prompt: nil, position: .toolbar); #expect(!indicator.view.isHidden)
        // Painting never polls the input source, even across repeated frames.
        #expect(reads == 1)
        NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        #expect(reads == 2)
        indicator.stop()
        NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        #expect(reads == 2)
    }
}
