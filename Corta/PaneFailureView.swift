import AppKit

/// What a pane shows when it has no terminal to show.
///
/// Three things have to exist before a pane can draw anything: a Metal
/// device, a glyph atlas built for the configured font, and a child process
/// on a PTY. Each of those can fail on a machine Corta is otherwise fine on —
/// a `$SHELL` pointing at a file that was uninstalled, a restored working
/// directory on an unmounted volume, a GPU that reports no device — and until
/// M7 each failure was a `fatalError` or a `try!`, so the answer to "your
/// login shell moved" was a crash report.
///
/// The view is deliberately plain: an icon, a sentence naming what failed, the
/// underlying error, and the two actions that can actually help. Failure is
/// signalled by the symbol *and* the words, never by colour alone — a red
/// panel says nothing to a person who cannot separate red from grey, and this
/// is the one screen that has to be readable when everything else is broken.
@MainActor
final class PaneFailureView: NSView {
    /// The pane is being asked to build itself again — the shell was
    /// reinstalled, the volume was remounted.
    var onRetry: (() -> Void)?
    /// Open the settings page, which is where `$SHELL`-adjacent choices and
    /// the config file live.
    var onOpenSettings: (() -> Void)?

    init(title: String, detail: String, canRetry: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        // Not `.systemRed`: the shape carries the meaning, and the label
        // colour keeps it legible under Increase Contrast and in both
        // appearances.
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityLabel(title)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.isSelectable = true

        var buttons: [NSView] = []
        if canRetry {
            let retry = NSButton(
                title: L10n.text("failure.button.retry"), target: self,
                action: #selector(retryTapped))
            retry.keyEquivalent = "\r"
            buttons.append(retry)
        }
        let settings = NSButton(
            title: L10n.text("failure.button.settings"), target: self,
            action: #selector(settingsTapped))
        buttons.append(settings)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [icon, titleLabel, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        // One group with a spoken description, rather than four unrelated
        // elements VoiceOver reads in layout order.
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @objc private func retryTapped() { onRetry?() }
    @objc private func settingsTapped() { onOpenSettings?() }
}
