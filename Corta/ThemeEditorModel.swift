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
import Observation

/// An unsaved draft: previews never change the live configuration. Saving
/// uses the same atomic file/rollback path as every other setting.
@MainActor @Observable final class ThemeEditorModel: Identifiable {
    let id = UUID()
    let themeID: String
    let baseline: Theme?
    let base: Theme
    var displayName: String
    var dark: Theme.Variant
    var light: Theme.Variant
    var revision = 0
    var isDark = true
    var error: String?

    init(source: Theme, editing: Bool) {
        themeID = editing ? source.name : "custom-" + UUID().uuidString.lowercased()
        baseline = editing ? source : nil
        base = source
        displayName = editing ? source.displayName : source.displayName + " " + L10n.text("theme.copySuffix")
        dark = source.dark
        light = source.light
    }

    var draft: Theme {
        Theme(name: themeID, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), dark: dark, light: light)
    }
    var canSave: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80 && !name.contains("#") && !name.contains("\n") && !name.contains("\r")
    }
    var variant: Theme.Variant { isDark ? dark : light }

    func color(_ index: Int) -> SIMD4<Float> {
        switch index {
        case 0: variant.foreground
        case 1: variant.background
        case 2: variant.cursor
        default: variant.ansi[index - 3]
        }
    }
    func setColor(_ index: Int, _ color: SIMD4<Float>) {
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite else { return }
        let color = SIMD4<Float>(min(1, max(0, color.x)), min(1, max(0, color.y)), min(1, max(0, color.z)), 1)
        var variant = variant
        switch index {
        case 0: variant.foreground = color
        case 1: variant.background = color
        case 2: variant.cursor = color
        default: variant.ansi[index - 3] = color
        }
        if isDark { dark = variant } else { light = variant }
    }
    func restoreVariant() {
        revision += 1
        if isDark { dark = base.dark } else { light = base.light }
    }

    @discardableResult func save(to store: ConfigurationStore = .shared) -> Bool {
        guard canSave else { error = L10n.text("theme.invalidName"); return false }
        if let baseline, store.configuration.customThemes.first(where: { $0.name == themeID }) != baseline {
            error = L10n.text("theme.conflict")
            return false
        }
        let value = draft
        guard store.update({ config in
            config.customThemes.removeAll { $0.name == value.name }
            config.customThemes.append(value)
            config.theme = value.name
        }) else {
            error = L10n.text("theme.saveFailed")
            return false
        }
        error = nil
        return true
    }
}
