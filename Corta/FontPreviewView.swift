import AppKit
import CortaTerminal

/// B09 — a read-only preview of the *currently resolved* theme and font in
/// the Appearance tab's own colours and glyphs, not the swatch of a picker.
/// Nothing here can be clicked or chosen; CLAUDE.md's settled "Corta offers
/// one theme and one font; it resolves several" is untouched — this shows
/// what that one theme and font actually look like instead of asking the
/// reader to imagine it from two names.
final class FontPreviewView: NSView {
    private let promptLine = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let textLine = NSTextField(labelWithString: "")
    private let background = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let stack = NSStackView(views: [promptLine, statusLine, textLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: background.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `appearance`, not `effectiveAppearance` sampled inside `configure`:
    /// the caller already knows which variant the rest of the app is
    /// painting with (`AppearanceController`'s resolution), and asking here
    /// too would risk disagreeing with it during a live appearance switch.
    func configure(theme: Theme, font: CTFont, isDark: Bool = NSApp.effectiveAppearance.name
        == .darkAqua) {
        let variant = theme.variant(dark: isDark)
        let nsFont = font as NSFont
        background.layer?.backgroundColor = Self.color(variant.background).cgColor

        promptLine.attributedStringValue = NSAttributedString(
            string: "~/corta $ echo hello",
            attributes: [.font: nsFont, .foregroundColor: Self.color(variant.foreground)])

        // Index 2 is ANSI green (success), 1 is ANSI red (failure) — the
        // same pair a passing/failing command's prompt mark already uses.
        let success = NSAttributedString(
            string: "ok  ", attributes: [.font: nsFont, .foregroundColor: Self.color(variant.ansi[2])])
        let failure = NSAttributedString(
            string: "failed",
            attributes: [.font: nsFont, .foregroundColor: Self.color(variant.ansi[1])])
        let status = NSMutableAttributedString(attributedString: success)
        status.append(failure)
        statusLine.attributedStringValue = status

        textLine.attributedStringValue = NSAttributedString(
            string: "The quick brown fox jumps over the lazy dog.",
            attributes: [.font: nsFont, .foregroundColor: Self.color(variant.foreground)])
    }

    private static func color(_ value: SIMD4<Float>) -> NSColor {
        NSColor(
            srgbRed: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z),
            alpha: CGFloat(value.w))
    }
}
