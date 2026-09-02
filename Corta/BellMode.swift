import Foundation

/// M4.8, app side — what a BEL does. The core only reports that a bell
/// happened (`Terminal.takeBell()`); this is the app's decision.
///
/// No settings GUI exists or is planned before M5 (`DESIGN.md` §6), so this
/// is read from `UserDefaults` rather than a preferences panel — `defaults
/// write com.corta.Corta bellMode <audible|visual|muted>` until one exists.
enum BellMode: String {
    /// `NSSound.beep()`. Off by default: an audible bell in a terminal that
    /// runs training jobs is hostile.
    case audible
    /// A brief flash of the terminal surface. The default — visible without
    /// being disruptive to whatever else is making noise nearby.
    case visual
    case muted

    private static let defaultsKey = "bellMode"

    static var current: BellMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(BellMode.init(rawValue:)) ?? .visual
    }
}
