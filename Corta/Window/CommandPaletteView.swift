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

/// The command palette, in SwiftUI, glass included.
/// `CommandPaletteModel` owns the state; `CommandPaletteController` only
/// hosts this view as its transparent panel's content and forwards
/// `show(_:)`.
///
/// Glass for floating chrome, like the search bar; one surface, so one
/// `GlassEffectContainer`. Reduce Transparency and Increase Contrast are
/// environment values: an opaque tint and a drawn border.
///
/// The search field keeps focus the whole time the palette is open — arrow
/// keys, Return and Escape are all read off it directly (`.onKeyPress`/
/// `.onExitCommand`) rather than through a table view's own selection, so
/// no local key-event monitor is needed: a text field never consumes
/// vertical arrow keys, and intercepting them at the field is enough.
struct CommandPaletteView: View {
    /// The panel's content size; the controller creates the panel from it.
    static let size = CGSize(width: 520, height: 360)

    @Bindable var model: CommandPaletteModel
    @FocusState private var searchFocused: Bool
    /// Nil: the system's settings (`GlassAccessibility`).
    var accessibilityOverride: GlassAccessibility?
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast

    private var accessibility: GlassAccessibility {
        accessibilityOverride ?? GlassAccessibility(
            reduceTransparency: systemReduceTransparency,
            increaseContrast: systemContrast == .increased)
    }
    private var reduceTransparency: Bool { accessibility.reduceTransparency }

    /// The window-corner radius (as `TerminalView`), not a pill: a panel
    /// reads as a window.
    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        GlassEffectContainer {
            content
                .cortaGlass(in: Self.shape, opaque: reduceTransparency)
                .overlay {
                    // An opaque panel has no material edge.
                    if let border = accessibility.panelBorder {
                        Self.shape.strokeBorder(Color(nsColor: border), lineWidth: 1)
                    }
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.text("commandPalette.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    model.runSelected()
                    return .handled
                }
                .onExitCommand { model.dismiss() }
            Divider()
            if model.rows.isEmpty {
                Text(L10n.text("commandPalette.empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rows) { row in
                                CommandPaletteRowView(
                                    row: row, isSelected: row.id == model.selectedRowID
                                )
                                .id(row.id)
                                .onTapGesture {
                                    guard row.command != nil else { return }
                                    model.select(row)
                                    model.runSelected()
                                }
                            }
                        }
                    }
                    // Only far enough to show the row: centring scrolled the list on
                    // every arrow press, even with the row already in view.
                    .onChange(of: model.selectedRowID) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
        .padding(16)
        // The panel's size is `CommandPaletteView.size`, title bar strip
        // included: the view fills whatever the panel is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
    }
}

private struct CommandPaletteRowView: View {
    let row: CommandPaletteModel.Row
    let isSelected: Bool

    var body: some View {
        switch row {
        case .header(let title):
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
        case .command(let command, _, let shortcut):
            HStack {
                Text(command.title).font(.system(size: 13))
                Spacer()
                // The system font, not a monospaced one: these are the same
                // ⌘⇧D / ← / ⇞ glyphs the menu bar draws, and the menu bar
                // draws them in the system face.
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            // One element with one name, so VoiceOver announces "Split Pane
            // Right, Command Shift D" instead of two adjacent labels.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shortcut.isEmpty ? command.title : "\(command.title), \(shortcut)")
        }
    }
}
