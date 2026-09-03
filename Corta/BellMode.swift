import Foundation

/// M4.8, app side — what a BEL does. The core only reports that a bell
/// happened (`Terminal.takeBell()`); this is the app's decision.
///
/// The value lives in the config file like every other setting, and nowhere
/// else. It used to be read from `UserDefaults` — written before the settings
/// page existed — and when the page arrived it wrote the config file while
/// the bell kept reading the defaults key, so changing Bell in Settings did
/// exactly nothing. Two stores for one setting is the failure mode
/// `CLAUDE.md` warns about, and this is what it looks like.
nonisolated enum BellMode: String, CaseIterable, Sendable {
    /// `NSSound.beep()`. Not the default: an audible bell in a terminal that
    /// runs training jobs is hostile.
    case audible
    /// A brief flash of the terminal surface. The default — visible without
    /// being disruptive to whatever else is making noise nearby.
    case visual
    case muted

    var displayName: String { rawValue.capitalized }
}
