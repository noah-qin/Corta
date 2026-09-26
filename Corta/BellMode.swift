import Foundation

/// What a BEL does. The core only reports that a bell
/// happened (`Terminal.takeBell()`); this is the app's decision.
///
/// The value lives in the config file like every other setting, and nowhere
/// else. A second store — a `UserDefaults` key the bell read while the
/// settings page wrote the file — would make changing Bell in Settings do
/// exactly nothing: the failure mode `docs/DECISIONS.md` D10 exists to
/// prevent.
nonisolated enum BellMode: String, CaseIterable, Sendable {
    /// `NSSound.beep()`. Not the default: an audible bell in a terminal that
    /// runs training jobs is hostile.
    case audible
    /// A brief flash of the terminal surface. The default — visible without
    /// being disruptive to whatever else is making noise nearby.
    case visual
    case muted

    /// The picker's label — localised, not the config-file word
    /// capitalised, which would read as English in every language.
    var displayName: String { L10n.text("bell.\(rawValue)") }
}
