import AppKit
import CortaTerminal

/// The About window.
///
/// It replaces `orderFrontStandardAboutPanel:`, which the storyboard wired up
/// and which showed the icon, the name, a version and then nothing: the panel
/// fills itself from `Info.plist`, `NSHumanReadableCopyright` was an empty
/// string, and there was no `Credits.rtf` to give it a body. The result was a
/// mostly empty box that answered none of the questions an About window is
/// opened to answer — what is this, which version am I running, where does it
/// live, what is it licensed under.
///
/// Everything shown here is read from the bundle rather than typed in a second
/// time. A version number written twice is a version number that goes stale:
/// `CFBundleShortVersionString` comes from `MARKETING_VERSION`, and the
/// terminal's own XTVERSION answer comes from `CortaVersion` — which this
/// window also shows, precisely so a mismatch between the two is visible
/// instead of silent.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L10n.text("about.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        let content = Self.buildContentView()
        window.contentView = content
        // Sized to the content rather than to the number the window was
        // created with: the stack's height depends on the icon, the font and
        // the length of the version line, and a guessed height leaves a band
        // of empty window under the copyright.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Content

    private static func buildContentView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
        ])

        let name = NSTextField(labelWithString: bundleString("CFBundleName") ?? "Corta")
        name.font = .systemFont(ofSize: 22, weight: .semibold)

        let tagline = NSTextField(labelWithString: L10n.text("about.tagline"))
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor

        let version = NSTextField(labelWithString: versionLine)
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        // The one line a bug report needs, so it can be copied out of here
        // rather than transcribed from a screenshot.
        version.toolTip = L10n.text("about.version.tooltip")

        let links = NSStackView(views: [
            linkButton(L10n.text("about.website"), "https://github.com/noah-qin/Corta"),
            linkButton(L10n.text("about.releaseNotes"), "https://github.com/noah-qin/Corta/releases"),
            linkButton(L10n.text("about.license"), "https://github.com/noah-qin/Corta/blob/main/LICENSE"),
        ])
        links.orientation = .horizontal
        links.spacing = 4

        let copyright = NSTextField(labelWithString: copyrightLine)
        copyright.font = .systemFont(ofSize: 10)
        copyright.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, name, tagline, version, links, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(14, after: tagline)
        stack.setCustomSpacing(14, after: version)
        stack.setCustomSpacing(16, after: links)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    /// `Version 0.1.0 (1)`, plus the terminal's self-reported version when it
    /// disagrees with the bundle's — see the note on the type.
    private static var versionLine: String {
        let short = bundleString("CFBundleShortVersionString") ?? "—"
        let build = bundleString("CFBundleVersion") ?? "—"
        var line = L10n.format("about.version", short, build)
        if short != CortaVersion.string { line += " · " + L10n.format("about.reportsVersion", CortaVersion.string) }
        return line
    }

    /// The bundle's copyright when it carries one, and a sensible line when
    /// it does not — an About window with a blank where the copyright goes is
    /// what this replaced.
    private static var copyrightLine: String {
        if let copyright = bundleString("NSHumanReadableCopyright"), !copyright.isEmpty {
            return copyright
        }
        return "Apache License 2.0"
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func linkButton(_ title: String, _ urlString: String) -> NSButton {
        let button = NSButton(title: title, target: LinkOpener.shared, action: #selector(LinkOpener.open(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(urlString)
        return button
    }

    /// A target for the link buttons. `NSButton` needs an object to send to,
    /// and the buttons are built in a static context; the URL travels on the
    /// button's identifier so one shared target serves all of them.
    @MainActor
    private final class LinkOpener: NSObject {
        static let shared = LinkOpener()

        @objc func open(_ sender: NSButton) {
            guard let string = sender.identifier?.rawValue, let url = URL(string: string) else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}
