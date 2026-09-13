import AppKit
import CoreText
import CortaTerminal
import SwiftUI

/// B09 — a read-only preview of the *currently resolved* theme and font in
/// the Appearance tab's own colours and glyphs, not the swatch of a picker.
/// Nothing here can be clicked or chosen; CLAUDE.md's settled "Corta offers
/// one theme and one font; it resolves several" is untouched — this shows
/// what that one theme and font actually look like instead of asking the
/// reader to imagine it from two names. SwiftUI replacement for
/// `FontPreviewView`.
struct FontPreviewSwiftUIView: View {
    let theme: Theme
    let font: CTFont
    var isDark: Bool = NSApp.effectiveAppearance.name == .darkAqua

    private var variant: Theme.Variant { theme.variant(dark: isDark) }
    private var nsFont: NSFont { font as NSFont }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("~/corta $ echo hello")
                .font(Font(nsFont))
                .foregroundStyle(Self.color(variant.foreground))
            (
                Text("ok  ").foregroundStyle(Self.color(variant.ansi[2]))
                    + Text("failed").foregroundStyle(Self.color(variant.ansi[1]))
            )
            .font(Font(nsFont))
            Text("The quick brown fox jumps over the lazy dog.")
                .font(Font(nsFont))
                .foregroundStyle(Self.color(variant.foreground))
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(Self.color(variant.background), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
    }

    private static func color(_ value: SIMD4<Float>) -> SwiftUI.Color {
        SwiftUI.Color(
            .sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z),
            opacity: Double(value.w))
    }
}
