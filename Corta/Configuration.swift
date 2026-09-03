import Foundation

/// M6.1 — everything the settings page can change, and the text format the
/// config file stores it in.
///
/// One file is the source of truth. The settings page edits that file and
/// reads it back; there is no second store to drift out of sync, and a
/// hand-edit in `$EDITOR` is as valid an input as a click. That constraint
/// is why this type owns both the values and their serialisation.
///
/// The format is `key = value`, one per line, `#` to end of line for
/// comments — chosen because it needs no third-party parser and stays
/// readable when hand-edited. An unknown key is preserved on write rather
/// than dropped: a config written by a newer Corta must survive a round trip
/// through an older one.
nonisolated struct Configuration: Equatable, Sendable {
    /// Which of a theme's two variants is live (M6.13).
    enum Appearance: String, CaseIterable, Sendable {
        /// Follow macOS, switching live when the system does.
        case auto
        case light
        case dark
    }

    var fontFamily: String = Configuration.systemFontFamily
    var fontSize: Double = 12
    var theme: String = Theme.corta.name
    var appearance: Appearance = .auto
    var scrollbackLines: Int = 10_000
    var bell: BellMode = .visual
    /// Whether a command that ran longer than `notificationThreshold` posts
    /// a notification when it finishes (M6.3).
    var notifyOnLongTask: Bool = false
    /// Seconds a command must run before finishing it is worth a
    /// notification. Below this a notification is noise — the user was
    /// watching.
    var notificationThreshold: Double = 30

    /// The sentinel meaning "whatever `NSFont.monospacedSystemFont` gives",
    /// which is the default and tracks the OS rather than pinning a face.
    static let systemFontFamily = "system"

    init() {}

    // MARK: - Parsing

    /// Parses a config file. Unparseable lines are skipped, not fatal: a
    /// typo in one setting must not cost the user every other setting, and
    /// the terminal has to start.
    ///
    /// Returns the parsed configuration and the keys it did not recognise,
    /// so `serialized(preserving:)` can write them back untouched.
    static func parse(_ text: String) -> (configuration: Configuration, unknown: [(String, String)]) {
        var configuration = Configuration()
        var unknown: [(String, String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if !configuration.apply(key: key, value: value) {
                unknown.append((key, value))
            }
        }
        return (configuration, unknown)
    }

    /// Applies one key. Returns false when the key is not one of ours — an
    /// out-of-range *value* for a known key is clamped, not rejected, so the
    /// key still counts as recognised and is rewritten in canonical form.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "font-family":
            fontFamily = value.isEmpty ? Self.systemFontFamily : value
        case "font-size":
            // The same clamp the ⌘+/⌘− path uses: below ~8pt the metrics
            // round to a degenerate cell.
            if let size = Double(value) { fontSize = min(64, max(8, size)) }
        case "theme":
            theme = Theme.named(value) != nil ? value : Theme.corta.name
        case "appearance":
            appearance = Appearance(rawValue: value) ?? .auto
        case "scrollback-lines":
            // Capped: scrollback is unbounded input and every unbounded
            // input needs a cap (`SECURITY.md` §3).
            if let lines = Int(value) { scrollbackLines = min(1_000_000, max(0, lines)) }
        case "bell":
            bell = BellMode(rawValue: value) ?? .visual
        case "notify-on-long-task":
            notifyOnLongTask = Self.parseBool(value) ?? false
        case "notification-threshold":
            if let seconds = Double(value) { notificationThreshold = max(1, seconds) }
        default:
            return false
        }
        return true
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: - Writing

    /// The file this configuration would be written as, with a header
    /// explaining that hand-edits are picked up — because they are, and a
    /// config file that does not say so invites the user to look for a
    /// hidden second store.
    func serialized(preserving unknown: [(String, String)] = []) -> String {
        var lines = [
            "# Corta configuration.",
            "#",
            "# This file is the single source of truth. The settings page edits it,",
            "# and an edit made here is picked up while Corta is running.",
            "",
            "font-family = \(fontFamily)",
            "font-size = \(Self.number(fontSize))",
            "theme = \(theme)",
            "appearance = \(appearance.rawValue)",
            "scrollback-lines = \(scrollbackLines)",
            "bell = \(bell.rawValue)",
            "notify-on-long-task = \(notifyOnLongTask)",
            "notification-threshold = \(Self.number(notificationThreshold))",
        ]
        if !unknown.isEmpty {
            lines.append("")
            lines.append("# Written by a different version of Corta and kept verbatim.")
            for (key, value) in unknown { lines.append("\(key) = \(value)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Trims a trailing `.0` so a whole number reads as one.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
