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

/// Help > Keyboard Shortcuts (⌘/) — every command Corta has, grouped, with
/// the key that runs it.
///
/// It owns no data. The rows are `TerminalCommand.allCases` grouped by
/// `category` with the shortcuts read from `ConfigurationStore`, which means a
/// command added to that table appears here for free, and a key rebound in
/// the config file is shown rebound — a printed cheat sheet that disagrees
/// with the running app is worse than none. `ShortcutsWindowController` only
/// hosts this view in an `NSHostingController`.
struct ShortcutsView: View {
    @State private var bindings = ConfigurationStore.shared.configuration.keybindings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = Self.commands(in: category)
                    if !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            Divider()
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                                ForEach(commands, id: \.self) { command in
                                    ShortcutRowView(title: command.title, shortcut: bindings[command]?.displayText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text(L10n.text("shortcuts.footnote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: ConfigurationStore.didChange)) { _ in
            bindings = ConfigurationStore.shared.configuration.keybindings
        }
    }

    private static func commands(in category: CommandCategory) -> [TerminalCommand] {
        TerminalCommand.allCases
            .filter { $0.category == category }
            .sorted { $0.paletteRank < $1.paletteRank }
    }
}

private struct ShortcutRowView: View {
    let title: String
    let shortcut: String?

    var body: some View {
        GridRow {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(shortcut ?? L10n.text("shortcuts.unbound"))
                .monospaced()
                .foregroundStyle(shortcut == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .gridColumnAlignment(.trailing)
                .fixedSize()
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            shortcut.map { L10n.format("shortcuts.a11yRow", title, $0) }
                ?? L10n.format("shortcuts.a11yUnbound", title))
    }
}
