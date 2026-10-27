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
import CoreText
import Observation

/// Status-row wording: a clamped value's bounds and a font family's origin.
extension SettingsModel {
    /// A bound as a person would write it. The fields hold whole numbers, but
    /// the font size and the notification threshold are `Double` — so the
    /// unformatted description said "Size must be between 8.0 and 64.0",
    /// which reads as a precision the setting does not have.
    static func plain(_ value: CustomStringConvertible) -> String {
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func clamp<T: Comparable & CustomStringConvertible>(
        _ value: T, _ low: T, _ high: T, label: String
    ) -> (T, String?) {
        let result = min(high, max(low, value))
        guard result != value else { return (result, nil) }
        let message = L10n.format(
            "settings.status.clamped", label, plain(low), plain(high), plain(result))
        return (result, message)
    }

    static func detail(forFamily family: String) -> String {
        guard family != Configuration.systemFontFamily else { return L10n.text("settings.font.origin.system") }
        guard let entry = MonospacedFontCatalog.entry(for: family) else { return "" }
        var lines: [String] = []
        switch entry.origin {
        case .apple: lines.append(L10n.text("settings.font.origin.apple"))
        case .user(let path):
            lines.append(L10n.format("settings.font.origin.user", (path as NSString).abbreviatingWithTildeInPath))
        }
        if entry.hasCJK { lines.append(L10n.text("settings.font.cjk")) }
        return lines.joined(separator: "\n")
    }
}
