import AppKit

/// The three System Settings > Accessibility > Display switches Corta has to
/// answer, in one place.
///
/// **Why one place.** Each of the three was being ignored independently — the
/// settings window animated its own resize, the search bar and the command
/// palette were built on `NSVisualEffectView` with no opaque alternative, and
/// state was signalled by colour alone. Answering them per call site meant
/// every new animation and every new panel had to remember three questions,
/// and the ones added after M6 did not. A single façade makes the answer a
/// one-line lookup, and `observe(_:)` makes a surface follow a change made
/// while the app is running rather than only at launch.
///
/// These are *system* preferences, deliberately not config-file keys: the user
/// has already expressed them once, for every app, and a second copy in
/// `~/.config/corta/config` would be a store that drifts from the one macOS
/// actually reports (`CLAUDE.md`).
@MainActor
enum SystemAccessibility {
    /// "Reduce motion". A surface that would animate should arrive at its
    /// final state immediately instead.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// "Reduce transparency". A glass or vibrancy material should be replaced
    /// by an opaque fill, not merely made less translucent — the point of the
    /// setting is that background content must not show through at all.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// "Increase contrast". Hairlines and secondary label colours are the two
    /// things that stop being legible; both get promoted.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The duration an animation should actually run for — zero under Reduce
    /// Motion, so a call site can keep its animation code and simply pass this
    /// instead of a literal.
    static func duration(_ preferred: CFTimeInterval) -> CFTimeInterval {
        reduceMotion ? 0 : preferred
    }

    /// The colour for secondary text: promoted to the full label colour under
    /// Increase Contrast, where a 60%-alpha grey on a light background falls
    /// below the contrast ratio the setting exists to guarantee.
    static var secondaryLabelColor: NSColor {
        increaseContrast ? .labelColor : .secondaryLabelColor
    }

    /// Same, one step fainter — the config-file path under the settings page,
    /// and anything else that is deliberately quiet until it is needed.
    static var tertiaryLabelColor: NSColor {
        increaseContrast ? .labelColor : .secondaryLabelColor
    }

    /// The border a panel draws to separate itself from what is behind it.
    /// Under Increase Contrast (or Reduce Transparency, where the panel is
    /// opaque and so has no material edge of its own) it has to be a visible
    /// line rather than a suggestion of one.
    static var panelBorder: (color: NSColor, width: CGFloat) {
        if increaseContrast { return (.labelColor, 1) }
        if reduceTransparency { return (.separatorColor, 1) }
        return (NSColor.white.withAlphaComponent(0.12), 1)
    }

    /// Registers `handler` for every one of the three changing, and calls it
    /// once immediately so a surface has one code path for "apply the current
    /// preferences" rather than one for setup and one for updates.
    ///
    /// The returned token must be retained by the observer; releasing it
    /// unregisters. AppKit posts a single notification for all of the display
    /// options, so there is one observer regardless of which switch moved.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> Any {
        let token = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        handler()
        return token
    }
}
