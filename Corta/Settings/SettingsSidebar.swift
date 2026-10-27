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

import SwiftUI

/// The sidebar's selection, shared by the sidebar, the page and the window
/// controller (which names the window after it).
@MainActor @Observable
final class SettingsNavigation {
    var selection: SettingsView.Category = .general
    var showHostDetails = false
    var themeEditorRequest = 0
}

/// The category list. AppKit hosts it as the split view's sidebar item, which
/// is what gives it the floating Liquid Glass sidebar; SwiftUI's own
/// `NavigationSplitView` inside a hosting controller drew a flush, opaque one.
struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        List(
            SettingsView.Category.allCases,
            selection: Binding(
                get: { navigation.selection },
                set: { if let category = $0 { navigation.selection = category } })
        ) { category in
            SettingsSidebarRow(category: category).tag(category)
        }
        .listStyle(.sidebar)
    }
}

/// A sidebar row the way System Settings draws one: the symbol white on a
/// coloured rounded tile, then the name. Explicit colours rather than a
/// `Label`'s accent tint — the tinted icons disappeared and came back for a
/// few frames each time the window opened and became key.
private struct SettingsSidebarRow: View {
    let category: SettingsView.Category

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(category.tileColor.gradient, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(category.title)
        }
    }
}
