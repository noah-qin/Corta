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

extension TerminalViewIMETests {
    static func shiftHome() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F729}",
            charactersIgnoringModifiers: "\u{F729}", isARepeat: false, keyCode: 115)!
    }

    // MARK: - Marked text / commit

    @Test func markedTextNeverReachesThePTY() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 5))
        #expect(bytes.isEmpty)
    }

    @Test func committedTextIsWrittenAsUTF8AndClearsThePreedit() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bytes == Array("中".utf8))
        #expect(!view.hasMarkedText())
        #expect(view.markedRange().location == NSNotFound)
    }

    @Test func insertTextAcceptsAttributedStrings() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.insertText(
            NSAttributedString(string: "中文"), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bytes == Array("中文".utf8))
    }

    @Test func emptyMarkedTextAndUnmarkBothClearThePreedit() {
        let view = Self.makeView()
        view.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.setMarkedText(
            "", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        view.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(!view.hasMarkedText())
    }

    @Test func doCommandForwardsTheKeysAnIMEConsumed() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(bytes == [0x0D, 0x7F, 0x1B] + Array("\u{1B}[A\u{1B}[B\u{1B}[D\u{1B}[C".utf8))
    }

    /// A candidate window (shell completion, an IME) can resolve Tab or
    /// Shift-Tab as a command instead of calling `insertText`. Before this,
    /// `doCommand(by:)` had no case for either selector and the keystroke was
    /// silently dropped — this is the exact seam the reported Claude Code
    /// slash-command Tab-completion failure went through.
    @Test func doCommandForwardsTabAndBacktab() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(bytes == [0x09] + Array("\u{1B}[Z".utf8))
    }

    // MARK: - Preedit overlay

    @Test func preeditOverlayAppearsAtTheCursorCell() {
        let view = Self.makeView()
        let cell = CGRect(x: 40, y: 17, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        view.setMarkedText(
            "zh", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first else {
            Issue.record("no preedit overlay was added")
            return
        }
        #expect(!overlay.isHidden)
        #expect(overlay.frame.origin == cell.origin)
        #expect(overlay.frame.width >= cell.width)
    }

    /// Found by looking at a light-appearance window: the preedit was drawn
    /// in near-white on a light background and could not be read. The overlay
    /// held its own copy of "the colour the renderer uses", which stopped
    /// being true once the palette started following the theme and the system
    /// appearance.
    @Test func preeditTakesItsColourFromTheLivePalette() throws {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        let saved = TerminalColorPalette.activeVariant
        defer { TerminalColorPalette.apply(saved) }

        func drawnColour(underForeground foreground: SIMD4<Float>) -> NSColor? {
            var variant = saved
            variant.foreground = foreground
            TerminalColorPalette.apply(variant)
            view.setMarkedText(
                "ni", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first,
                let drawn = overlay.markedText
            else { return nil }
            return drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }

        let onDark = try #require(
            drawnColour(underForeground: SIMD4<Float>(0.95, 0.95, 0.95, 1))?
                .usingColorSpace(.sRGB))
        let onLight = try #require(
            drawnColour(underForeground: SIMD4<Float>(0.1, 0.1, 0.1, 1))?
                .usingColorSpace(.sRGB))
        #expect(onDark.redComponent > 0.9)
        #expect(onLight.redComponent < 0.2)
    }

    @Test func preeditOverlayKeepsTheIMEUnderlineStyling() {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        let marked = NSAttributedString(
            string: "中文",
            attributes: [.underlineStyle: NSUnderlineStyle.thick.rawValue])
        view.setMarkedText(
            marked, selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first,
            let drawn = overlay.markedText
        else {
            Issue.record("no preedit overlay was added")
            return
        }
        let underline = drawn.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.thick.rawValue)
        // Display-only defaults are filled in where the IME set nothing.
        #expect(drawn.attribute(.font, at: 0, effectiveRange: nil) != nil)
        #expect(drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
    }

    /// The caret sits where the IME's selection puts it — the end while
    /// typing pinyin, inside the text while moving through it — not at the
    /// preedit's start, where the block cursor covered the first letter.
    @Test func preeditCaretFollowsTheIMESelection() throws {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        func caret(at location: Int) throws -> (location: Int, x: CGFloat) {
            view.setMarkedText(
                "you", selectedRange: NSRange(location: location, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            let overlay = try #require(
                view.subviews.compactMap { $0 as? MarkedTextOverlayView }.first)
            return (overlay.caretLocation, overlay.caretX)
        }
        let atEnd = try caret(at: 3)
        #expect(atEnd.location == 3)
        #expect(atEnd.x > 0)
        let atStart = try caret(at: 0)
        #expect(atStart.x == 0)
        let inside = try caret(at: 1)
        #expect(inside.x > 0 && inside.x < atEnd.x)
        #expect(try caret(at: NSNotFound).location == 3)
        #expect(try caret(at: 99).location == 3)
    }

    /// With no backdrop, what lay under the preedit showed through it: the
    /// block cursor, and in Claude Code its own inverted cursor cell.
    @Test func preeditCoversTheCellsUnderIt() throws {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 48, height: 17) }
        let saved = TerminalColorPalette.activeVariant
        defer { TerminalColorPalette.apply(saved) }
        var variant = saved
        variant.background = SIMD4<Float>(1, 0, 0, 1)
        TerminalColorPalette.apply(variant)
        view.setMarkedText(
            "a", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let overlay = try #require(
            view.subviews.compactMap { $0 as? MarkedTextOverlayView }.first)
        let bitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        // Right of the one letter, clear of the caret at its start.
        let x = Int(CGFloat(bitmap.pixelsWide) * 0.8)
        let pixel = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        // Red, as the palette says, give or take the bitmap's colour space.
        #expect(pixel.redComponent > 0.9 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3)
    }

    // MARK: - Candidate window placement

    /// `NSView.inputContext` is documented to return nil unless the receiver
    /// conforms to `NSTextInputClient` — this pins that the conformance
    /// actually engages AppKit's input machinery, the precondition for every
    /// IME behaviour above.
    @Test func inputContextEngagesWhenFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        #expect(view.inputContext != nil)
    }

    @Test func firstRectIsTheCursorCellInScreenCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        let cell = CGRect(x: 16, y: 34, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(rect == window.convertToScreen(view.convert(cell, to: nil)))
        #expect(rect.size == cell.size)
        #expect(rect != .zero)
    }
}
