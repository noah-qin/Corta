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

// The compact native previews come from 1.6old's settings components.
struct SettingsIconTile: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct SettingsThumbnail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.43, green: 0.70, blue: 1.0), Color(red: 0.11, green: 0.43, blue: 0.90)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            content()
        }
    }
}

/// A miniature window: light, dark, or split down the middle for Auto.
struct AppearanceThumbnail: View {
    let appearance: Configuration.Appearance

    var body: some View {
        SettingsThumbnail {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                }
                .frame(height: 4)
                .padding(5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.gray.opacity(0.18))
                    .padding(EdgeInsets(top: 15, leading: 6, bottom: 6, trailing: 6))
            }
            .frame(width: 62, height: 44)
        }
    }

    private var fill: AnyShapeStyle {
        let light = Color.white
        let dark = Color(red: 0.11, green: 0.12, blue: 0.14)
        switch appearance {
        case .light: return AnyShapeStyle(light)
        case .dark: return AnyShapeStyle(dark)
        case .auto:
            return AnyShapeStyle(
                LinearGradient(
                    stops: [.init(color: light, location: 0.5), .init(color: dark, location: 0.5)],
                    startPoint: .init(x: 0.35, y: 0), endPoint: .init(x: 0.65, y: 1)))
        }
    }
}

/// `ls` with the cursor shape after it.
struct CursorThumbnail: View {
    let shape: Configuration.CursorShape

    var body: some View {
        SettingsThumbnail {
            HStack(alignment: .bottom, spacing: 2) {
                Text(verbatim: "ls")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                switch shape {
                case .block: RoundedRectangle(cornerRadius: 2).frame(width: 12, height: 24)
                case .bar: RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 24)
                case .underline: RoundedRectangle(cornerRadius: 1).frame(width: 12, height: 3).padding(.bottom, 3)
                }
            }
            .foregroundStyle(.white)
        }
    }
}

/// One symbol per bell mode.
struct BellThumbnail: View {
    let mode: BellMode

    var body: some View {
        SettingsThumbnail {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white)
        }
    }

    private var symbol: String {
        switch mode {
        case .visual: "eye"
        case .audible: "speaker.wave.2"
        case .muted: "speaker.slash"
        }
    }
}

// MARK: - Theme card

/// A theme as the eye would meet it: its background, "Aa" in its text
/// colour, a path chip in its blue, the cursor, and the eight ANSI colours.
struct ThemePreviewCard: View {
    let theme: Theme
    let isDark: Bool
    let isSelected: Bool
    let action: () -> Void

    private var variant: Theme.Variant { theme.variant(dark: isDark) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(verbatim: "Aa")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(color(variant.foreground))
                        Text(verbatim: "~/")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(color(variant.ansi[4]))
                            .background(color(variant.ansi[4]).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        RoundedRectangle(cornerRadius: 2).fill(color(variant.cursor)).frame(width: 8, height: 20)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: -5) {
                        ForEach(0..<8, id: \.self) { index in
                            Circle().fill(color(variant.ansi[index]))
                                .overlay(Circle().strokeBorder(color(variant.background), lineWidth: 1.5))
                                .frame(width: 16, height: 16)
                        }
                    }
                }
                .padding(EdgeInsets(top: 11, leading: 13, bottom: 10, trailing: 13))
                .frame(width: 132, height: 80, alignment: .leading)
                .background(color(variant.background), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                )
                .padding(2.5)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16.5, style: .continuous)
                )
                .padding(2.5)
                .background(
                    isSelected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                Text(theme.displayName)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 132)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("theme-card-\(theme.name)")
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func color(_ value: SIMD4<Float>) -> Color {
        Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: 1)
    }
}

struct SettingsAppearancePreview: View {
    let appearance: Configuration.Appearance
    var body: some View { AppearanceThumbnail(appearance: appearance).accessibilityHidden(true) }
}

extension Color {
    init(themeColor value: SIMD4<Float>) {
        self.init(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: Double(value.w))
    }
}
