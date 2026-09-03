import AppKit

/// M7.4 — what a window was, in enough detail to open it again.
///
/// **Not the terminal's contents.** A pane is a live child process; a
/// scrollback restored without the process that produced it is a screenshot
/// pretending to be a session, and the prompt in it would answer to nothing.
/// What is worth restoring is the *arrangement*: how many windows, how they
/// were split, how the dividers sat, and which directory each pane was in —
/// which is the part a person actually rebuilds by hand after a restart.
nonisolated struct WindowState: Codable, Equatable, Sendable {
    var frame: Frame
    var layout: PaneLayout

    struct Frame: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }
}

/// The split tree, as a value. Mirrors `SplitTree`'s shape: a leaf is a pane,
/// a node is exactly two children and a divider.
nonisolated indirect enum PaneLayout: Codable, Equatable, Sendable {
    /// A pane, and the working directory it last reported through OSC 7.
    case pane(directory: String?)
    /// - Parameter position: the divider as a *fraction* of the node's axis,
    ///   not points. A restored window may open on a different display, or at
    ///   a size the user changed since; a fraction keeps the proportions the
    ///   user set instead of stranding one pane at its minimum.
    case split(vertical: Bool, position: Double, first: PaneLayout, second: PaneLayout)

    /// The first pane in tree order — the one a restored window's root pane
    /// has to be, since that pane is created before the layout is applied.
    var firstDirectory: String? {
        switch self {
        case .pane(let directory): return directory
        case .split(_, _, let first, _): return first.firstDirectory
        }
    }
}

/// Reads and writes the saved arrangement.
///
/// Application Support, not the config file: this is state Corta maintains,
/// not settings a person edits, and mixing the two would mean the config file
/// churned on every window move. `restore-windows = false` stops it being
/// read *and* written, so turning the feature off leaves nothing behind.
@MainActor
enum SessionRestore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corta/state.json")
    }

    /// The saved windows, oldest first, or an empty array when there is
    /// nothing to restore. A malformed file is treated as no file: a
    /// terminal that refuses to launch because its restore state is corrupt
    /// is worse than one that opens a fresh window.
    static func load() -> [WindowState] {
        guard let data = try? Data(contentsOf: fileURL),
            let states = try? JSONDecoder().decode([WindowState].self, from: data)
        else { return [] }
        return states
    }

    static func save(_ states: [WindowState]) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(states)
            try data.write(to: url, options: .atomic)
        } catch {
            // Losing the arrangement is not worth interrupting a quit for.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
