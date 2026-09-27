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

/// The kitty keyboard protocol's progressive-enhancement flags. Legacy
/// encoding cannot tell `Ctrl+I` from `Tab` (both `0x09`), so an editor
/// binding them differently needs this.
///
/// Every flag is declared so the `CSI ? u` query reports the whole word, but
/// only `supported` is stored: a program must see that a flag did not take.
public struct KeyboardEnhancementFlags: OptionSet, Sendable, Equatable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let disambiguate = KeyboardEnhancementFlags(rawValue: 1)
    public static let reportEventTypes = KeyboardEnhancementFlags(rawValue: 2)
    public static let reportAlternateKeys = KeyboardEnhancementFlags(rawValue: 4)
    public static let reportAllKeysAsEscapeCodes = KeyboardEnhancementFlags(rawValue: 8)
    public static let reportAssociatedText = KeyboardEnhancementFlags(rawValue: 16)

    public static let supported: KeyboardEnhancementFlags = [.disambiguate, .reportEventTypes]
}

/// A stack, as the protocol specifies: a program that runs a child (`vim` in
/// `tmux`) must be able to restore exactly what it found.
public struct KeyboardProtocolStack: Sendable, Equatable {
    /// Pushed by the byte stream, so capped (`SECURITY.md` §3), as kitty does.
    static let maximumDepth = 32

    private var stack: [KeyboardEnhancementFlags] = [[]]

    public init() {}

    /// Never empty: the base entry is the legacy encoding.
    public var current: KeyboardEnhancementFlags { stack[stack.count - 1] }

    public var depth: Int { stack.count }

    /// `CSI > flags u`. At the cap the oldest entry goes, so a program that
    /// never pops is not stuck at what it last set.
    public mutating func push(_ flags: KeyboardEnhancementFlags) {
        stack.append(flags.intersection(.supported))
        if stack.count > Self.maximumDepth { stack.removeFirst() }
    }

    /// `CSI < number u`, default 1.
    public mutating func pop(_ count: Int) {
        for _ in 0..<max(1, count) where stack.count > 1 { stack.removeLast() }
    }

    /// `CSI = flags ; mode u` — 1 sets, 2 adds, 3 removes.
    public mutating func set(_ flags: KeyboardEnhancementFlags, mode: Int) {
        let requested = flags.intersection(.supported)
        switch mode {
        case 2: stack[stack.count - 1].formUnion(requested)
        case 3: stack[stack.count - 1].subtract(requested)
        default: stack[stack.count - 1] = requested
        }
    }
}
