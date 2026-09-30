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

import Carbon.HIToolbox

/// `typeText` delivers key events, and a CJK input method composes them
/// into candidates instead of passing them to the terminal — every typed
/// line would silently go nowhere. A test that types selects a Latin
/// keyboard layout for its own duration and puts the user's choice back
/// afterwards, so nothing about the machine is changed once it has run.
enum LatinInputSource {
    /// Selects `com.apple.keylayout.ABC` (or any enabled Latin keyboard
    /// layout) and returns what was selected before, or `nil` when the
    /// current source is already a plain keyboard layout.
    static func select() -> TISInputSource? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func property(_ source: TISInputSource, _ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        if property(current, kTISPropertyInputSourceType) == "TISTypeKeyboardLayout" {
            return nil
        }
        let filter = [kTISPropertyInputSourceType as String: "TISTypeKeyboardLayout"]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
            as? [TISInputSource]
        else { return nil }
        let abc = list.first { property($0, kTISPropertyInputSourceID) == "com.apple.keylayout.ABC" }
            ?? list.first
        guard let abc, TISSelectInputSource(abc) == noErr else { return nil }
        return current
    }

    /// Puts back what `select()` replaced; nothing when it replaced nothing.
    static func restore(_ previous: TISInputSource?) {
        if let previous { TISSelectInputSource(previous) }
    }
}
