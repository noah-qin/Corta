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

struct ThemeEditorView: View {
    @Bindable var editor: ThemeEditorModel
    let previewFont: CTFont
    @Environment(\.dismiss) private var dismiss
    @State private var invalidFields: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("theme.editor")).font(.title2.bold())
                Spacer()
                Picker(L10n.text("theme.variant"), selection: $editor.isDark) {
                    Text(L10n.text("settings.appearance.light")).tag(false)
                    Text(L10n.text("settings.appearance.dark")).tag(true)
                }.pickerStyle(.segmented).frame(width: 180)
                    .accessibilityIdentifier("theme-variant")
                    .onChange(of: editor.isDark) { _, _ in invalidFields.removeAll() }
            }.padding(24)
            SettingsPage {
                SettingsSection {
                    LabeledContent(L10n.text("theme.name")) {
                        TextField("", text: $editor.displayName).labelsHidden().frame(width: 260)
                            .accessibilityIdentifier("theme-name")
                    }
                    FontPreviewSwiftUIView(theme: editor.draft, font: previewFont, isDark: editor.isDark)
                        .accessibilityIdentifier("theme-preview")
                }
                colorSection(L10n.text("settings.themes.baseColors"), indices: 0..<3)
                colorSection(L10n.text("settings.themes.ansiColors"), indices: 3..<19)
            }
            if let error = editor.error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 24)
            }
            Divider()
            HStack {
                Button(L10n.text("theme.restore")) {
                    editor.restoreVariant()
                    invalidFields.removeAll()
                }
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("theme.save")) { if editor.save() { dismiss() } }
                    .disabled(!editor.canSave || !invalidFields.isEmpty)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("theme-save")
            }.padding(20)
        }.frame(width: 620, height: 650)
    }

    private func colorSection(_ title: String, indices: Range<Int>) -> some View {
        SettingsSection(title) {
            ForEach(indices, id: \.self) { index in
                ThemeEditorColorRow(
                    index: index, value: editor.color(index), onChange: { editor.setColor(index, $0) },
                    onValidity: { valid in
                        if valid { invalidFields.remove(index) } else { invalidFields.insert(index) }
                    }
                )
                .id("\(editor.isDark)-\(editor.revision)-\(index)")
            }
        }
    }

}

private struct ThemeEditorColorRow: View {
    let index: Int
    let value: SIMD4<Float>
    let onChange: (SIMD4<Float>) -> Void
    let onValidity: (Bool) -> Void
    @State private var hex = ""
    private var label: String {
        index < 3 ? L10n.text("theme.color.\(index)") : "ANSI \(index - 3)"
    }
    var body: some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Spacer()
            ColorPicker(
                label,
                selection: Binding(
                    get: {
                        Color(
                            nsColor: NSColor(
                                srgbRed: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z), alpha: 1
                            ))
                    },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        onChange(
                            SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
                        )
                        onValidity(true)
                    }), supportsOpacity: false
            ).labelsHidden()
                .accessibilityIdentifier("theme-color-\(index)")
            TextField("HEX", text: $hex).font(.system(.body, design: .monospaced)).frame(width: 90)
                .accessibilityIdentifier("theme-hex-\(index)")
                .onChange(of: hex) { _, text in
                    if let color = Theme.color(text) {
                        onChange(color)
                        onValidity(true)
                    } else {
                        onValidity(false)
                    }
                }
        }
        .onAppear { hex = Theme.hex(value) }
        .onChange(of: value) { _, color in
            let canonical = Theme.hex(color)
            if Theme.color(hex) != color { hex = canonical }
        }
    }
}
