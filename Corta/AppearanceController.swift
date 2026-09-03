import AppKit

/// M6.2 and M6.13 — resolves the configured theme and appearance into the
/// one live colour variant, and keeps it live.
///
/// Two inputs decide the answer: which theme the config names, and whether
/// the terminal should be dark. The second is either forced by the config or
/// follows macOS, and when it follows macOS it has to change *while running*
/// — the user toggling Dark Mode re-themes every open window with no
/// restart, which is the whole point of the item.
///
/// The observation is KVO on `NSApp.effectiveAppearance` rather than the
/// distributed `AppleInterfaceThemeChanged` notification: the distributed
/// one fires before AppKit has updated the app, so reading the appearance
/// from its handler gives the value that is about to be replaced.
@MainActor
final class AppearanceController: NSObject {
    static let shared = AppearanceController()

    /// Posted after the live variant changes, so panes redraw. Separate from
    /// `ConfigurationStore.didChange` because the system appearance can
    /// change this without the configuration changing at all.
    static let didChange = Notification.Name("dev.noahqin.Corta.appearanceDidChange")

    private var appearanceObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: ConfigurationStore.didChange, object: nil)
    }

    /// Called once from `applicationDidFinishLaunching`, after `NSApp`
    /// exists — `effectiveAppearance` has no meaning before then.
    func start() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    /// The live theme: a built-in, or one the config file defines (M7.6).
    /// An unknown name falls back to the default rather than failing — the
    /// file is hand-edited, and a typo must not black out the terminal.
    var theme: Theme {
        let configuration = ConfigurationStore.shared.configuration
        return Theme.named(configuration.theme, in: configuration) ?? .corta
    }

    /// Whether the dark variant is live. `auto` asks AppKit, which is also
    /// what makes the answer change when the user toggles Dark Mode.
    var isDark: Bool {
        switch ConfigurationStore.shared.configuration.appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    func apply() {
        // An explicit choice overrides the system for the whole app, so the
        // titlebar and the settings page match the terminal surface rather
        // than contradicting it. `nil` hands the decision back to macOS.
        let forced: NSAppearance?
        switch ConfigurationStore.shared.configuration.appearance {
        case .auto: forced = nil
        case .light: forced = NSAppearance(named: .aqua)
        case .dark: forced = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance != forced { NSApp.appearance = forced }

        TerminalColorPalette.apply(theme.variant(dark: isDark))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    @objc private func configurationChanged() { apply() }
}
