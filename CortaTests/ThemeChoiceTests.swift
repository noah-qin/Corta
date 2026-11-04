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
import Testing

@testable import Corta

/// Light and dark appearances choose their themes apart: `theme = name`
/// for both, `theme = light:a,dark:b` for two.
@Suite struct ThemeChoiceTests {
    @Test func oneNameServesBothAppearances() {
        let (parsed, unknown) = Configuration.parse("theme = solarized")
        #expect(unknown.isEmpty)
        #expect(parsed.themeName(dark: false) == "solarized")
        #expect(parsed.themeName(dark: true) == "solarized")
        #expect(parsed.serialized().contains("theme = solarized\n"))
    }

    @Test func twoNamesRoundTrip() {
        let (parsed, unknown) = Configuration.parse("theme = light:solarized, dark:mono")
        #expect(unknown.isEmpty)
        #expect(parsed.themeName(dark: false) == "solarized")
        #expect(parsed.themeName(dark: true) == "mono")
        #expect(parsed.serialized().contains("theme = light:solarized,dark:mono\n"))
        let reparsed = Configuration.parse(parsed.serialized()).configuration
        #expect(reparsed.theme == parsed.theme)
        #expect(reparsed.darkTheme == parsed.darkTheme)
    }

    @Test func aSideLeftOutIsTheDefaultAndTheSameNameTwiceIsOne() {
        #expect(Configuration.themeChoice("dark:mono")! == (light: "corta", dark: "mono"))
        #expect(Configuration.themeChoice("light:mono")! == (light: "mono", dark: "corta"))
        #expect(Configuration.themeChoice("light:mono,dark:mono")! == (light: "mono", dark: nil))
        #expect(Configuration.themeChoice("")! == (light: "corta", dark: nil))
    }

    @Test(arguments: ["light:", "sepia:mono", "light:a,light:b", "light:a,,dark:b"])
    func aMalformedChoiceIsRefused(_ value: String) {
        #expect(Configuration.themeChoice(value) == nil)
    }

    @Test func choosingOneAppearanceKeepsTheOther() {
        var configuration = Configuration()
        configuration.setTheme("solarized", dark: false)
        #expect(configuration.themeName(dark: false) == "solarized")
        #expect(configuration.themeName(dark: true) == "corta")
        configuration.setTheme("mono", dark: true)
        #expect(configuration.themeName(dark: false) == "solarized")
        #expect(configuration.themeName(dark: true) == "mono")
        // Back to one theme for both: written as one name again.
        configuration.setTheme("solarized", dark: true)
        #expect(configuration.darkTheme == nil)
        #expect(configuration.themeChoice == "solarized")
        // The View menu's choice is for both.
        configuration.setTheme("mono", dark: true)
        configuration.setTheme("corta")
        #expect(configuration.themeName(dark: true) == "corta")
        #expect(configuration.darkTheme == nil)
    }

    @Test func thePanesDrawEachAppearanceFromItsOwnTheme() {
        var configuration = Configuration()
        configuration.setTheme("solarized", dark: false)
        configuration.setTheme("mono", dark: true)
        let theme = Theme.selected(in: configuration)
        #expect(theme.light == Theme.solarized.light)
        #expect(theme.dark == Theme.mono.dark)
        #expect(Theme.selected(in: Configuration()) == .corta)
    }

    @Test func bothSelectedThemesAreListed() {
        var configuration = Configuration()
        configuration.theme = "gone"
        configuration.darkTheme = "solarized"
        let names = Theme.all(in: configuration).map(\.name)
        #expect(names.contains("solarized"))
        // An unknown name falls back to the default for drawing.
        #expect(Theme.selected(in: configuration).light == Theme.corta.light)
    }

    @Test func aBlendRunsFromOneVariantToTheOther() {
        let from = Theme.corta.dark
        let to = Theme.corta.light
        #expect(from.mixed(with: to, by: 0) == from)
        #expect(from.mixed(with: to, by: 1) == to)
        let half = from.mixed(with: to, by: 0.5)
        #expect(abs(half.background.x - (from.background.x + to.background.x) / 2) < 0.0001)
        #expect(half.ansi.count == 16)
    }

    /// What programs were told before a switch lands (mode 2031).
    @Test(arguments: [Theme.corta, Theme.mono, Theme.solarized])
    func variantsKnowTheirDarkness(_ theme: Theme) {
        #expect(theme.dark.isDarkBackground)
        #expect(!theme.light.isDarkBackground)
    }

    /// Every built-in hue reads on its background; Solarized is kept as
    /// published, so it is not held to this.
    @Test(arguments: [Theme.corta, Theme.mono])
    func builtInHuesKeepTheirContrast(_ theme: Theme) {
        func luminance(_ color: SIMD4<Float>) -> Float {
            func channel(_ value: Float) -> Float {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.x) + 0.7152 * channel(color.y) + 0.0722 * channel(color.z)
        }
        func contrast(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for variant in [theme.dark, theme.light] {
            #expect(contrast(variant.foreground, variant.background) >= 7)
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                #expect(contrast(variant.ansi[index], variant.background) >= 4.5, "\(theme.name) ansi \(index)")
            }
        }
    }
}
