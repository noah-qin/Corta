import AppKit

/// Help > Keyboard Shortcuts (⌘/) — every command Corta has, grouped, with
/// the key that runs it.
///
/// **Why this exists.** Splitting a pane, resizing one, jumping between
/// commands, switching theme, scrolling the history: all of it was reachable
/// only by already knowing which menu it was under, or by opening the command
/// palette, which is itself the most hidden thing in the app. A terminal is
/// exactly the sort of application whose users will learn a shortcut list on
/// sight and never open a menu again — but only if there is a list.
///
/// It owns no data. The rows are `TerminalCommand.allCases` grouped by
/// `category` with the shortcuts read from `ConfigurationStore`, which means a
/// command added to that table appears here for free, and a key rebound in
/// the config file is shown rebound — a printed cheat sheet that disagrees
/// with the running app is worse than none.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    private let stack = NSStackView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("shortcuts.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContentView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild), name: ConfigurationStore.didChange, object: nil)
        rebuild()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        // Rebuilt on open as well as on config change: the window is created
        // once and may have been closed for a while.
        rebuild()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func buildContentView() -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.autohidesScrollers = true

        // A document view that tracks the clip view's width, so the rows
        // stretch and the shortcut column stays flush right at any size.
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
            .isActive = true
        return scrollView
    }

    @objc private func rebuild() {
        stack.views.forEach { $0.removeFromSuperview() }
        let bindings = ConfigurationStore.shared.configuration.keybindings
        for category in CommandCategory.allCases {
            let commands = TerminalCommand.allCases
                .filter { $0.category == category }
                .sorted { $0.paletteRank < $1.paletteRank }
            guard !commands.isEmpty else { continue }
            stack.addView(header(category.title), in: .top)
            for command in commands {
                stack.addView(
                    row(command.title, bindings[command]?.displayText), in: .top)
            }
            stack.setCustomSpacing(18, after: stack.views.last!)
        }
        // Unbound commands are listed too, with an em dash rather than being
        // hidden: "this exists and has no key" is the information a person
        // looking for a key to bind actually needs.
        stack.addView(footnote(L10n.text("shortcuts.footnote")), in: .top)
    }

    private func header(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = SystemAccessibility.secondaryLabelColor
        return label
    }

    private func row(_ title: String, _ shortcut: String?) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail

        let key = NSTextField(labelWithString: shortcut ?? "—")
        key.font = .systemFont(ofSize: 13)
        key.alignment = .right
        key.textColor = shortcut == nil ? .tertiaryLabelColor : .labelColor
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [name, NSView(), key])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        // One element, one announcement — the pairing is the content.
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel(
            shortcut.map { L10n.format("shortcuts.a11yRow", title, $0) }
                ?? L10n.format("shortcuts.a11yUnbound", title))
        return row
    }

    private func footnote(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = SystemAccessibility.secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }
}
