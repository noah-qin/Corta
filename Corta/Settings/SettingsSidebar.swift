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
    private(set) var selection: SettingsView.Category = .general
    private var backStack: [SettingsView.Category] = []
    private var forwardStack: [SettingsView.Category] = []
    var showHostDetails = false
    var themeEditorRequest = 0

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(to category: SettingsView.Category) {
        guard category != selection else { return }
        backStack.append(selection)
        forwardStack.removeAll()
        selection = category
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(selection)
        selection = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selection)
        selection = next
    }
}

/// The category list. AppKit hosts it as the split view's sidebar item, which
/// is what gives it the floating Liquid Glass sidebar; SwiftUI's own
/// `NavigationSplitView` inside a hosting controller drew a flush, opaque one.
struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation

    @State private var search = ""
    @Environment(\.colorScheme) private var colorScheme

    private var categories: [SettingsView.Category] {
        SettingsView.Category.allCases.filter { $0.matches(search) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45))
                TextField(L10n.text("settings.search.placeholder"), text: $search)
                    .textFieldStyle(.plain).accessibilityIdentifier("settings-search")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("settings.search.clear"))
                }
            }
            .padding(.horizontal, 10).frame(height: 30).background(Color.primary.opacity(0.055), in: .capsule)
            .padding(.horizontal, 12).padding(.top, 6)
            if categories.isEmpty {
                Text(L10n.text("settings.search.empty")).foregroundStyle(.secondary).padding()
            }
            List(categories) { category in
                Button {
                    navigation.go(to: category)
                } label: {
                    SettingsSidebarRow(category: category)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.9) : Color(white: 0.15))
                .background(
                    navigation.selection == category ? Color.primary.opacity(0.07) : .clear,
                    in: .rect(cornerRadius: 10)
                )
                .accessibilityAddTraits(navigation.selection == category ? [.isSelected] : [])
                .listRowInsets(
                    EdgeInsets(
                        top: search.isEmpty && [.terminal, .connections, .privacy].contains(category) ? 12 : 1,
                        leading: 6, bottom: 1, trailing: 6))
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onMoveCommand { direction in
                guard let index = categories.firstIndex(of: navigation.selection) else { return }
                switch direction {
                case .up: navigation.go(to: categories[max(0, index - 1)])
                case .down: navigation.go(to: categories[min(categories.count - 1, index + 1)])
                default: break
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())
    }
}

/// A sidebar row the way System Settings draws one: the symbol white on a
/// coloured rounded tile, then the name. Explicit colours rather than a
/// `Label`'s accent tint — the tinted icons disappeared and came back for a
/// few frames each time the window opened and became key.
private struct SettingsSidebarRow: View {
    let category: SettingsView.Category

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(color: category.tileColor, symbol: category.symbol, size: 24)
            Text(category.title).font(.system(size: 13))
        }.padding(.vertical, 2)
    }
}
