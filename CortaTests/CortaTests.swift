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

    @Test func defaultForegroundStaysBright() {
        #expect(TerminalColorPalette.defaultForeground.x == Float(0.96))
        #expect(TerminalColorPalette.defaultForeground.y == Float(0.96))
        #expect(TerminalColorPalette.defaultForeground.z == Float(0.96))
    }

}
