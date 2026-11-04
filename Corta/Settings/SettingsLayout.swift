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

/// Shared spacing and neutral surfaces, with separate light and dark treatments
/// and stronger boundaries when Increase Contrast is enabled.
struct SettingsPage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 22).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.975))
        .labeledContentStyle(SettingsLabelStyle())
        .toggleStyle(.switch)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
    }
}

struct SettingsSectionAction {
    let title: String
    let symbol: String
    let identifier: String
    let handler: () -> Void
}

struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var title: String = ""
    var summary: String = ""
    var action: SettingsSectionAction?
    @ViewBuilder var content: Content

    init(
        _ title: String = "", summary: String = "", action: SettingsSectionAction? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let action {
                        Button(action: action.handler) { Label(action.title, systemImage: action.symbol) }
                            .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier(action.identifier)
                    }
                }.padding(.horizontal, 10)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index != rows.startIndex { Divider().padding(.horizontal, 12) }
                        rows[index]
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(minHeight: 42)
                    }
                }
            }
            .background(
                colorScheme == .dark ? Color.white.opacity(0.035) : Color(white: 0.945),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                }
            }
            if !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct SettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: LabeledContentStyleConfiguration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            configuration.label.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

/// Reusable selection treatment for previews, with a non-color selection cue.
struct SettingsChoice<Content: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                content
                    .frame(width: 112, height: 76)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    .padding(2.5)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16.5))
                    .padding(2.5)
                    .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 19))
                Text(title).font(.callout.weight(selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 122)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
