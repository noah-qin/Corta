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
import CortaTerminal
import SwiftUI

/// Preview the selected appearance, fixed primary font and configured cursor.
/// Theme-editor previews use the draft colors without changing live settings.
struct FontPreviewSwiftUIView: View {
    let theme: Theme
    let font: CTFont
    var isDark: Bool = NSApp.effectiveAppearance.name == .darkAqua

    var cursorStyle: CursorStyle?

    private var variant: Theme.Variant { theme.variant(dark: isDark) }
    private var nsFont: NSFont { font as NSFont }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: "~/corta $ echo hello")
                    .font(Font(nsFont))
                    .foregroundStyle(Self.color(variant.foreground))
                if let cursorStyle {
                    if cursorStyle == .blinkingBlock || cursorStyle == .blinkingBar || cursorStyle == .blinkingUnderline {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            previewCursor(cursorStyle)
                                .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
                        }
                    } else { previewCursor(cursorStyle) }
                }
            }
            // Two colours in one line, as two runs side by side: `Text + Text`
            // is deprecated on macOS 26, and interpolating styled `Text`s
            // makes a `"%@%@"` localizable key Xcode extracts into the
            // catalog. `verbatim` throughout — this is sample terminal
            // output, not UI copy.
            // The gap is the second run's leading spaces, not the first
            // run's trailing ones: a trailing-aligned form column dropped
            // those and drew "okfailed".
            HStack(spacing: 0) {
                Text(verbatim: "ok").foregroundStyle(Self.color(variant.ansi[2]))
                Text(verbatim: "  failed").foregroundStyle(Self.color(variant.ansi[1]))
            }
            .font(Font(nsFont))
            Text(verbatim: "The quick brown fox jumps over the lazy dog.")
                .font(Font(nsFont))
                .foregroundStyle(Self.color(variant.foreground))
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(Self.color(variant.background), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
    }

    private func previewCursor(_ style: CursorStyle) -> some View {
        let bar = style == .bar || style == .blinkingBar
        let underline = style == .underline || style == .blinkingUnderline
        let width = CGFloat(CTFontGetSize(font)) * 0.6
        let height = CGFloat(CTFontGetSize(font)) * 1.25
        return Rectangle().fill(Self.color(variant.cursor))
            .frame(width: bar ? 1 : width, height: underline ? 1 : height)
            .frame(width: width, height: height, alignment: underline ? .bottomLeading : .leading)
    }

    private static func color(_ value: SIMD4<Float>) -> SwiftUI.Color {
        SwiftUI.Color(
            .sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z),
            opacity: Double(value.w))
    }
}
