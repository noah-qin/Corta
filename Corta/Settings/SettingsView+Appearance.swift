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

// MARK: - Appearance

extension SettingsView {
    var appearancePage: some View {
        SettingsPage {
            SettingsSection(L10n.text("settings.section.colorScheme")) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Configuration.Appearance.allCases, id: \.self) { appearance in
                        SettingsChoice(
                            title: L10n.text(
                                appearance == .auto
                                    ? "settings.appearance.followSystem"
                                    : "settings.appearance.\(appearance.rawValue)"),
                            selected: model.appearance == appearance,
                            action: { model.set(\.appearance, appearance) },
                            content: { SettingsAppearancePreview(appearance: appearance) }
                        )
                        .accessibilityIdentifier("appearance-\(appearance.rawValue)")
                    }
                }
                Button {
                    navigation.go(to: .themes)
                } label: {
                    HStack {
                        Text(L10n.text("settings.tab.themes"))
                        Spacer()
                        Text(model.previewTheme.displayName).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
                            .tertiary)
                    }
                    .contentShape(.rect)
                }.buttonStyle(.plain)
            }
            SettingsSection(L10n.text("settings.section.font")) {
                FontPreviewSwiftUIView(
                    theme: model.previewTheme, font: model.previewFont, isDark: model.previewIsDark,
                    cursorStyle: model.cursorShape.style(blinking: model.cursorBlink)
                )
                .accessibilityLabel(L10n.text("settings.label.preview"))
                .accessibilityIdentifier("appearance-preview")
                .accessibilityValue(model.previewIsDark ? "dark" : "light")
                VStack(alignment: .leading, spacing: 5) {
                    FontFamilyPicker(
                        title: L10n.text("settings.label.font"),
                        selection: bind(model.fontFamily, model.setFontFamily),
                        defaultTag: Configuration.systemFontFamily,
                        defaultLabel: L10n.text("settings.font.systemMonospaced"), entries: model.availableFonts
                    )
                    .accessibilityIdentifier("font-family")
                    .help(L10n.text("settings.help.font"))
                    .task { await model.loadFonts() }
                    if !model.fontDetail.isEmpty {
                        Text(model.fontDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("font-detail")
                    }
                }
                if model.fontStatus.kind != .none {
                    LabeledContent(L10n.text("settings.label.fontStatus")) {
                        StatusRowView(
                            status: model.fontStatus,
                            action: Self.action(if: model.fontStatus.kind == .failed) {
                                model.retryFontResolution()
                            })
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    FontFamilyPicker(
                        title: L10n.text("settings.label.cjkFont"),
                        selection: bind(model.cjkFontFamily, model.setCJKFontFamily),
                        defaultTag: Configuration.automaticCJKFontFamily,
                        defaultLabel: L10n.text("settings.font.cjkAutomatic"), entries: model.availableCJKFonts
                    )
                    .accessibilityIdentifier("font-family-cjk")
                    .help(L10n.text("settings.help.cjkFont"))
                    // Fallback off draws only the font: the CJK font would never be used.
                    .disabled(!model.fontFallback)
                    if !model.cjkFontNotice.isEmpty {
                        Text(model.cjkFontNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cjk-font-notice")
                    }
                }
                LabeledContent(L10n.text("settings.label.size")) {
                    Stepper(value: bind(model.fontSize, model.setFontSize), in: Configuration.fontSizeRange) {
                        Text(model.fontSize, format: .number)
                    }
                }
                Picker(L10n.text("settings.label.fontWeight"), selection: bind(\.fontWeight)) {
                    ForEach(Configuration.FontWeight.allCases, id: \.self) { weight in
                        Text(L10n.text("settings.fontWeight.\(weight.rawValue)")).tag(weight)
                    }
                }
                .accessibilityIdentifier("font-weight")
                .help(L10n.text("settings.help.fontWeight"))
                LabeledContent(L10n.text("settings.label.lineSpacing")) {
                    Stepper(
                        value: bind(model.lineSpacing, model.setLineSpacing),
                        in: Configuration.lineSpacingRange,
                        step: Configuration.lineSpacingStep
                    ) {
                        Text(model.lineSpacing, format: .number.precision(.fractionLength(2)))
                    }
                }
                .accessibilityIdentifier("line-spacing")
                Toggle(L10n.text("settings.label.fontFallback"), isOn: bind(\.fontFallback))
                    .accessibilityIdentifier("font-fallback")
                Picker(L10n.text("settings.label.emojiRendering"), selection: bind(\.emojiRendering)) {
                    ForEach(Configuration.EmojiRendering.allCases, id: \.self) { mode in
                        Text(L10n.text("settings.emojiRendering.\(mode.rawValue)")).tag(mode)
                    }
                }
                .accessibilityIdentifier("emoji-rendering")
            }
            SettingsSection(L10n.text("settings.section.cursor")) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Configuration.CursorShape.allCases, id: \.self) { shape in
                        SettingsChoice(
                            title: L10n.text("settings.cursor.\(shape.rawValue)"),
                            selected: model.cursorShape == shape,
                            action: { model.set(\.cursorShape, shape) },
                            content: { CursorThumbnail(shape: shape) }
                        ).accessibilityIdentifier("cursor-shape-\(shape.rawValue)")
                    }
                }
                Toggle(L10n.text("settings.label.cursorBlink"), isOn: bind(\.cursorBlink))
                    .accessibilityIdentifier("cursor-blink")
                    .help(L10n.text("settings.help.cursor"))
            }
            statusBarSections
        }
    }

    /// The window's optional bottom bar: part of how a window looks, whatever
    /// it reports.
    @ViewBuilder private var statusBarSections: some View {
            SettingsSection(L10n.text("status.settings")) {
                Toggle(L10n.text("status.enable"), isOn: bind(\.statusBar))
                    .accessibilityIdentifier("status-bar-enable")
                Button {
                    navigation.showHostDetails = true
                } label: {
                    HStack {
                        Text(L10n.text("status.details"))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityIdentifier("host-details")
            }
            SettingsSection(L10n.text("settings.status.items"), summary: L10n.text("status.settings.help")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 2), spacing: 20) {
                    ForEach(SystemMetrics.Item.allCases, id: \.self) { item in
                        Toggle(
                            L10n.text("status.item.\(item.rawValue)"),
                            isOn: Binding(
                                get: { model.statusItems.contains(item) },
                                set: { model.setStatusItem(item, enabled: $0) })
                        )
                        .accessibilityIdentifier("status-item-\(item.rawValue)")
                    }
                }.padding(.vertical, 4)
                StatusNetworkInterfaceField(model: model)
            }.disabled(!model.statusBar)
    }
}
