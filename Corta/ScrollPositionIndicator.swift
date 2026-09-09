import AppKit

/// U12 — where you are in the history, and one click back to the bottom.
///
/// **The problem.** A terminal scrolled up looks exactly like a terminal that
/// has stopped producing output. There is no scroll bar — the pane is a
/// `CAMetalLayer`, not an `NSScrollView` — so nothing says "there are four
/// thousand lines below this", and nothing says "the build you are waiting
/// for has printed since you scrolled". A person who scrolls up to read an
/// error and then waits for the next one waits forever, watching a screen
/// that is not the live screen.
///
/// **The shape.** One pill in the bottom-right corner, present only while the
/// viewport is off the bottom. It says how far back it is, changes its words
/// (not just its colour) when output has arrived since, and clicking it —
/// anywhere on it — returns to the live screen. It never covers the cursor,
/// which is on the live screen and therefore not on screen while this is.
@MainActor
final class ScrollPositionIndicator: NSView {
    /// Tapped, or Return/Space pressed on it: go back to the live screen.
    var onReturnToBottom: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous

        icon.image = NSImage(
            systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.button)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How far back the viewport is, and whether the child has printed since.
    ///
    /// `hasNewOutput` changes the **words**, not only the tint: "new output"
    /// is the fact a person is waiting for, and a colour-only signal is no
    /// signal at all to a reader who cannot separate the two colours — the
    /// same rule `PaneFailureView` follows.
    func update(linesBack: Int, hasNewOutput: Bool) {
        let text =
            hasNewOutput
            ? L10n.text("scrollback.newOutput")
            : L10n.format("scrollback.position", Self.formatted(linesBack))
        label.stringValue = text
        icon.image = NSImage(
            systemSymbolName: hasNewOutput ? "arrow.down.circle.fill" : "arrow.down.to.line",
            accessibilityDescription: nil)
        self.hasNewOutput = hasNewOutput
        applyColors()
        setAccessibilityLabel("\(text). \(L10n.text("scrollback.returnToBottom"))")
        toolTip = L10n.text("scrollback.returnToBottom")
    }

    private(set) var hasNewOutput = false

    /// Grouped digits, because "12,340 lines back" is a number a person reads
    /// and "12340" is one they count.
    ///
    /// The formatter is built once. This is called on every scroll tick while
    /// the pill is visible, and `NumberFormatter()` is not a cheap object to
    /// build — it reads the current locale each time.
    private static let lineCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func formatted(_ lines: Int) -> String {
        lineCountFormatter.string(from: NSNumber(value: lines)) ?? String(lines)
    }

    private func applyColors() {
        // The accent colour carries "there is something new" *in addition to*
        // the words; the resting state is the ordinary control material so
        // the pill does not compete with the terminal's own text.
        layer?.backgroundColor =
            (hasNewOutput ? NSColor.controlAccentColor : NSColor.controlBackgroundColor)
            .withAlphaComponent(0.92).cgColor
        let foreground: NSColor = hasNewOutput ? .white : .secondaryLabelColor
        label.textColor = foreground
        icon.contentTintColor = foreground
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        onReturnToBottom?()
    }

    override func accessibilityPerformPress() -> Bool {
        onReturnToBottom?()
        return true
    }
}
