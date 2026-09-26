import AppKit
import CoreText
import CortaTerminal
import SwiftUI

/// A read-only preview of the *currently resolved* theme and font in
/// the Appearance tab's own colours and glyphs, not the swatch of a picker.
/// Nothing here can be clicked or chosen; `docs/DECISIONS.md` D11's "Corta offers
/// one theme and one font; it resolves several" is untouched — this shows
/// what that one theme and font actually look like instead of asking the
/// reader to imagine it from two names.
struct FontPreviewSwiftUIView: View {
    let theme: Theme
    let font: CTFont
    var isDark: Bool = NSApp.effectiveAppearance.name == .darkAqua

    private var variant: Theme.Variant { theme.variant(dark: isDark) }
    private var nsFont: NSFont { font as NSFont }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "~/corta $ echo hello")
                .font(Font(nsFont))
                .foregroundStyle(Self.color(variant.foreground))
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
