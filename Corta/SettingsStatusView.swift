import AppKit

/// The one line on the settings page that says what just happened.
///
/// **Why it exists.** Every control on that page writes the config file the
/// moment it changes, which is the right behaviour and was also completely
/// silent: a saved change, a value quietly clamped from 200 to 64, and a write
/// that failed outright all looked identical — nothing moved except, on the
/// clamp, the number in the field, which reads as the app ignoring what was
/// typed.
///
/// **Why an icon and a word, never a colour.** A green tick and a red cross
/// are the same shape to a person who cannot separate those hues, and this
/// line is the only report the page makes. The symbol carries the state, the
/// sentence carries the detail, and the tint is the third and least load-
/// bearing signal — so the row still works in greyscale, under Increase
/// Contrast, and read aloud.
@MainActor
final class SettingsStatusView: NSView {
    enum State: Equatable {
        /// Nothing to report; the row is invisible but keeps its height, so
        /// the page does not jump every time a switch is flipped.
        case none
        case saved
        /// The value was written, but not the value that was typed.
        case adjusted(String)
        case failed(String)
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private var retryAction: (() -> Void)?
    private var clearWork: DispatchWorkItem?
    private var accessibilityObserver: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retryButton.title = L10n.text("settings.status.retry")
        retryButton.bezelStyle = .accessoryBarAction
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true
        retryButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, retryButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Reserved whether or not there is anything to say, so the window
            // does not resize by a line on every keystroke.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 17),
        ])
        // One announcement, not three unrelated elements read in order.
        setAccessibilityRole(.staticText)
        accessibilityObserver = SystemAccessibility.observe { [weak self] in
            self?.applyState()
        }
        show(.none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var state: State = .none

    /// A success or a clamp clears itself after a few seconds — it is a
    /// confirmation, not a condition. A failure stays: it describes a state
    /// the file is still in, and it carries the only action that can fix it.
    /// - Parameter actionTitle: overrides the button's label. The default is
    ///   "Retry", which is right for a failed write and wrong for "Open
    ///   System Settings" — the same row, a different action.
    func show(_ state: State, retry: (() -> Void)? = nil, actionTitle: String? = nil) {
        clearWork?.cancel()
        clearWork = nil
        self.state = state
        retryAction = retry
        retryButton.title = actionTitle ?? L10n.text("settings.status.retry")
        applyState()
        guard state != .none, retry == nil else { return }
        if case .failed = state { return }
        let work = DispatchWorkItem { [weak self] in self?.show(.none) }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearDelay, execute: work)
    }

    private static let clearDelay: TimeInterval = 4

    private func applyState() {
        let symbol: String?
        let text: String
        let tint: NSColor
        switch state {
        case .none:
            symbol = nil
            text = ""
            tint = .labelColor
        case .saved:
            symbol = "checkmark.circle.fill"
            text = L10n.text("settings.status.saved")
            tint = SystemAccessibility.secondaryLabelColor
        case .adjusted(let detail):
            symbol = "info.circle.fill"
            text = detail
            tint = .labelColor
        case .failed(let detail):
            symbol = "exclamationmark.triangle.fill"
            text = detail
            tint = .labelColor
        }
        icon.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        // The tint is the *third* signal. Under Increase Contrast even that
        // much colour separation is unreliable, so the symbol carries it
        // alone and everything settles on the label colour.
        icon.contentTintColor = SystemAccessibility.increaseContrast ? .labelColor : symbolTint
        icon.isHidden = symbol == nil
        label.stringValue = text
        label.textColor = tint
        label.toolTip = text.isEmpty ? nil : text
        retryButton.isHidden = retryAction == nil
        setAccessibilityLabel(text.isEmpty ? nil : text)
        if !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
    }

    /// Colour, used only to reinforce a symbol that already says the same
    /// thing. Not `systemGreen`/`systemRed`: the pair is the classic
    /// indistinguishable one, and neither hue adds anything the tick and the
    /// triangle have not already said.
    private var symbolTint: NSColor {
        switch state {
        case .none, .saved: .secondaryLabelColor
        case .adjusted: .systemBlue
        case .failed: .systemOrange
        }
    }

    @objc private func retryTapped() { retryAction?() }
}
