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

/// F13 and above, Insert, and the keys AppKit reports as private-use scalars
/// (U+F700–U+F8FF). F13 used to reach the child as the UTF-8 of U+F710.
@MainActor
struct TerminalViewFunctionKeyTests {
    private static func key(
        _ scalar: UInt32, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown, isRepeat: Bool = false
    ) -> NSEvent {
        let text = String(UnicodeScalar(scalar)!)
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers.union(.function), timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: isRepeat, keyCode: keyCode)!
    }

    private static func sequence(_ text: String) -> [UInt8] { Array(("\u{1B}[" + text).utf8) }

    struct LegacyKey: Sendable, CustomTestStringConvertible {
        let scalar: UInt32
        let keyCode: UInt16
        let number: Int
        var testDescription: String { "F\(13 + Int(scalar - 0xF710))" }
    }

    /// F13–F20: scalar, Mac key code, xterm number.
    nonisolated static let legacyKeys: [LegacyKey] = [
        .init(scalar: 0xF710, keyCode: 105, number: 25), .init(scalar: 0xF711, keyCode: 107, number: 26),
        .init(scalar: 0xF712, keyCode: 113, number: 28), .init(scalar: 0xF713, keyCode: 106, number: 29),
        .init(scalar: 0xF714, keyCode: 64, number: 31), .init(scalar: 0xF715, keyCode: 79, number: 32),
        .init(scalar: 0xF716, keyCode: 80, number: 33), .init(scalar: 0xF717, keyCode: 90, number: 34),
    ]

    @Test("F13–F20 send xterm's CSI number ~", arguments: legacyKeys)
    func legacyFunctionKeys(_ key: LegacyKey) {
        #expect(TerminalView.bytes(for: Self.key(key.scalar, keyCode: key.keyCode)) == Self.sequence("\(key.number)~"))
    }

    @Test("a modified F13–F20 carries the modifier as CSI number ; m ~", arguments: legacyKeys)
    func modifiedLegacyFunctionKeys(_ key: LegacyKey) {
        #expect(
            TerminalView.bytes(for: Self.key(key.scalar, keyCode: key.keyCode, modifiers: .shift))
                == Self.sequence("\(key.number);2~"))
        #expect(
            TerminalView.bytes(for: Self.key(key.scalar, keyCode: key.keyCode, modifiers: [.control, .option]))
                == Self.sequence("\(key.number);7~"))
    }

    @Test("Insert sends CSI 2 ~, with modifiers CSI 2 ; m ~")
    func insert() {
        #expect(TerminalView.bytes(for: Self.key(0xF727, keyCode: 114)) == Self.sequence("2~"))
        #expect(TerminalView.bytes(for: Self.key(0xF727, keyCode: 114, modifiers: .shift)) == Self.sequence("2;2~"))
    }

    @Test("under kitty's flags, F13–F35 are 57376…57398", arguments: Array(0..<23))
    func kittyFunctionKeys(_ index: Int) {
        let event = Self.key(0xF710 + UInt32(index))
        let code = 57376 + index
        #expect(TerminalView.bytes(for: event, enhancements: .disambiguate) == Self.sequence("\(code)u"))
        #expect(
            TerminalView.bytes(for: Self.key(0xF710 + UInt32(index), modifiers: .control), enhancements: .disambiguate)
                == Self.sequence("\(code);5u"))
    }

    @Test("with event types, F13 reports press, repeat and release")
    func kittyEventTypes() {
        let flags: KeyboardEnhancementFlags = [.disambiguate, .reportEventTypes]
        #expect(TerminalView.bytes(for: Self.key(0xF710), enhancements: flags) == Self.sequence("57376u"))
        #expect(
            TerminalView.bytes(for: Self.key(0xF710, isRepeat: true), enhancements: flags)
                == Self.sequence("57376;1:2u"))
        #expect(
            TerminalView.bytes(for: Self.key(0xF710, type: .keyUp), enhancements: flags)
                == Self.sequence("57376;1:3u"))
        // Without event types a release sends nothing, as for every key.
        #expect(TerminalView.bytes(for: Self.key(0xF710, type: .keyUp), enhancements: .disambiguate) == nil)
    }

    @Test("with event types, Insert is CSI 2 ; m:e ~")
    func kittyInsert() {
        #expect(
            TerminalView.bytes(for: Self.key(0xF727, keyCode: 114), enhancements: .reportEventTypes)
                == Self.sequence("2;1:1~"))
    }

    /// F21–F35 outside kitty, Help, Print Screen, Begin, Menu and the rest of
    /// the block: none has a sequence, and none may reach the child as text.
    @Test(
        "a private-use key without an encoding sends nothing",
        arguments: [0xF718, 0xF726, 0xF746, 0xF72E, 0xF72A, 0xF735, 0xF8FF] as [UInt32])
    func unencodedPrivateUseKeys(_ scalar: UInt32) {
        #expect(TerminalView.bytes(for: Self.key(scalar)) == nil)
        #expect(TerminalView.bytes(for: Self.key(scalar, modifiers: .option), optionAsMeta: true) == nil)
        #expect(TerminalView.bytes(for: Self.key(scalar, modifiers: .control)) == nil)
    }
}
