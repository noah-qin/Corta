//
//  CortaTests.swift
//  CortaTests
//
//  Created by Noah on 9/1/26.
//

import CoreGraphics
import Testing
import CortaTerminal
@testable import Corta

struct CortaTests {

    @MainActor @Test func defaultFontMatchesTerminalProfile() {
        #expect(ViewController.defaultFontSize == CGFloat(12))
    }

    /// The live palette follows the theme and the system appearance now
    /// (M6.2, M6.13), so the assertion is against the default theme's dark
    /// variant — the value this test was written to pin — rather than
    /// against whichever variant happens to be live in the test process.
    @Test func defaultForegroundStaysBright() {
        let foreground = Theme.corta.dark.foreground
        #expect(foreground.x > 0.9)
        #expect(foreground.x == foreground.y)
        #expect(foreground.y == foreground.z)
    }

}
