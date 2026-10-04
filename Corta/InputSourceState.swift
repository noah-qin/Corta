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
import Carbon

/// Describes only what the public input-source metadata can establish. An
/// IME's private ASCII toggle is not inferred from the last typed character.
nonisolated struct InputSourceState: Equatable, Sendable {
    enum Kind: Sendable { case direct, nonLatinLayout, ime, unknown }
    var identifier: String
    var name: String
    var badge: String
    var kind: Kind

    static func classify(identifier: String, name: String, languages: [String],
        isKeyboardLayout: Bool, mode: String?) -> Self {
        let language = languages.first ?? ""
        let token = mode?.lowercased() ?? ""
        let appleMode = identifier.hasPrefix("com.apple.inputmethod.")
        let direct = isKeyboardLayout && Locale.Language(identifier: language).script?.identifier == "Latn"
            || appleMode && (token.hasSuffix(".roman") || token.hasSuffix(".halfwidthroman"))
        if direct { return .init(identifier: identifier, name: name, badge: "A", kind: .direct) }
        let badge: String
        if language.hasPrefix("zh") { badge = "中" }
        else if language.hasPrefix("ja") { badge = "あ" }
        else if language.hasPrefix("ko") { badge = "한" }
        else { badge = String(language.split(separator: "-").first ?? "IME").uppercased() }
        // Built-in non-Roman IME modes report their selection publicly. Third
        // party methods may hide an internal ASCII toggle: show a neutral badge.
        let nonLatinLayout = isKeyboardLayout
            && Locale.Language(identifier: language).script.map { $0.identifier != "Latn" } == true
        return .init(identifier: identifier, name: name, badge: badge,
            kind: nonLatinLayout ? .nonLatinLayout : appleMode && !isKeyboardLayout ? .ime : .unknown)
    }
}

/// Automatic visibility follows enabled sources, including explicit script
/// variants (e.g. Serbian Latin versus Cyrillic), rather than region or locale.
nonisolated enum InputSourceVisibility {
    static func needsIndicator(languages: [String], isKeyboardLayout: Bool) -> Bool {
        if languages.contains(where: {
            guard let script = Locale.Language(identifier: $0).script?.identifier else { return false }
            return script != "Latn"
        }) { return true }
        // An IME with incomplete metadata can still compose non-ASCII text.
        return !isKeyboardLayout
    }
}

@MainActor enum SystemInputSource {
    static func hasRelevantEnabledSources() -> Bool {
        let filter = [kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        return sources.contains { source in
            let type: String? = property(source, kTISPropertyInputSourceType)
            guard type == kTISTypeKeyboardLayout as String
                || type == kTISTypeKeyboardInputMethodWithoutModes as String
                || type == kTISTypeKeyboardInputMethodModeEnabled as String
                || type == kTISTypeKeyboardInputMode as String else { return false }
            let languages: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
            return InputSourceVisibility.needsIndicator(languages: languages,
                isKeyboardLayout: type == kTISTypeKeyboardLayout as String)
        }
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    static func current() -> InputSourceState? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property<T>(_ key: CFString, as: T.Type) -> T? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
        }
        let id = property(kTISPropertyInputSourceID, as: String.self) ?? ""
        let name = property(kTISPropertyLocalizedName, as: String.self) ?? id
        let languages = property(kTISPropertyInputSourceLanguages, as: [String].self) ?? []
        let type = property(kTISPropertyInputSourceType, as: String.self)
        return .classify(identifier: id, name: name, languages: languages,
            isKeyboardLayout: type == kTISTypeKeyboardLayout as String,
            mode: property(kTISPropertyInputModeID, as: String.self))
    }
}
