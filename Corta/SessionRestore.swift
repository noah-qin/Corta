import AppKit

/// M7.4 — what a window was, in enough detail to open it again.
///
/// **Not the terminal's contents.** A pane is a live child process; a
/// scrollback restored without the process that produced it is a screenshot
/// pretending to be a session, and the prompt in it would answer to nothing.
/// What is worth restoring is the *arrangement*: how many windows, how they
/// were split, how the dividers sat, and which directory each pane was in —
/// which is the part a person actually rebuilds by hand after a restart.
nonisolated struct WindowState: Equatable, Sendable {
    /// B09 — bumped whenever the shape of a saved `WindowState` changes in a
    /// way `decodeIfPresent` alone can't paper over. Absent entirely in data
    /// saved before this existed, which is exactly what makes `0` the right
    /// default for it: nothing else about that data needs migrating yet,
    /// only new fields defaulting sensibly (`decode(from:)` below).
    static let currentVersion = 1

    var version: Int
    var frame: Frame
    var layout: PaneLayout
    /// B09 — `NSWindow.tabbingIdentifier` at save time, so windows that were
    /// tabbed together can be regrouped on restore instead of each coming
    /// back as its own standalone window. `nil` for a window that was never
    /// tabbed, or for data saved before this existed.
    var tabGroupID: String?
    /// This window's position within its tab group at save time, oldest
    /// first — `nil` alongside `tabGroupID`.
    var tabIndex: Int?
    /// Whether this was the frontmost tab in its group. Defaults `true` on
    /// decode: a window saved before this existed, or one that was never
    /// tabbed, is its own only tab and was trivially the selected one.
    var isSelectedTab: Bool

    init(
        frame: Frame, layout: PaneLayout, tabGroupID: String? = nil, tabIndex: Int? = nil,
        isSelectedTab: Bool = true
    ) {
        self.version = Self.currentVersion
        self.frame = frame
        self.layout = layout
        self.tabGroupID = tabGroupID
        self.tabIndex = tabIndex
        self.isSelectedTab = isSelectedTab
    }

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

        /// The saved rectangle, moved and shrunk until it is somewhere the
        /// user can actually reach it.
        ///
        /// A frame is saved in global screen coordinates against the displays
        /// that existed at the time. Unplug the external monitor, change its
        /// resolution, or restore on a laptop that was docked, and the saved
        /// origin names a point no display covers — so the window opens
        /// entirely off-screen, with no titlebar to drag and no entry in
        /// Window > Zoom that brings it back. AppKit does not correct this
        /// for a frame set programmatically.
        ///
        /// The rule: pick the screen the saved frame overlaps most (falling
        /// back to the main screen when it overlaps none), clamp the size to
        /// that screen's visible frame, and then push the origin back inside
        /// it. `visibleFrame`, not `frame`, so a restored window never opens
        /// under the menu bar or behind the Dock.
        /// A saved size that could not have come from a real window: a
        /// hand-edited or truncated state file can hold `0`, a negative, or
        /// `NaN`, and `NSWindow.setFrame` with any of them produces a window
        /// nothing can recover — `min`/`max` against `NaN` propagate it
        /// silently rather than clamping it away, so the check has to come
        /// first (U07).
        static let minimumSize = CGSize(width: 320, height: 200)
        static let defaultSize = CGSize(width: 900, height: 560)

        var isUsable: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && width >= Self.minimumSize.width && height >= Self.minimumSize.height
        }

        func onScreen(_ screens: [NSScreen] = NSScreen.screens) -> NSRect {
            let saved =
                isUsable
                ? rect
                : NSRect(
                    origin: x.isFinite && y.isFinite ? rect.origin : .zero,
                    size: Self.defaultSize)
            let target =
                screens.max(by: {
                    $0.visibleFrame.intersection(saved).area
                        < $1.visibleFrame.intersection(saved).area
                }) ?? NSScreen.main
            guard let visible = target?.visibleFrame, !visible.isEmpty else { return saved }
            var result = saved
            result.size.width = min(result.width, visible.width)
            result.size.height = min(result.height, visible.height)
            result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
            result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
            return result
        }
    }
}

nonisolated extension WindowState: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, frame, layout, tabGroupID, tabIndex, isSelectedTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        frame = try container.decode(Frame.self, forKey: .frame)
        layout = try container.decode(PaneLayout.self, forKey: .layout)
        tabGroupID = try container.decodeIfPresent(String.self, forKey: .tabGroupID)
        tabIndex = try container.decodeIfPresent(Int.self, forKey: .tabIndex)
        isSelectedTab = try container.decodeIfPresent(Bool.self, forKey: .isSelectedTab) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(frame, forKey: .frame)
        try container.encode(layout, forKey: .layout)
        try container.encodeIfPresent(tabGroupID, forKey: .tabGroupID)
        try container.encodeIfPresent(tabIndex, forKey: .tabIndex)
        try container.encode(isSelectedTab, forKey: .isSelectedTab)
    }
}

extension NSRect {
    /// Zero for a null rectangle, which is what `intersection` returns when
    /// there is no overlap at all — and what makes "the screen it overlaps
    /// most" a total ordering.
    fileprivate nonisolated var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}

/// The split tree, as a value. Mirrors `SplitTree`'s shape: a leaf is a pane,
/// a node is exactly two children and a divider.
nonisolated indirect enum PaneLayout: Equatable, Sendable {
    /// A pane, the working directory it last reported through OSC 7, the
    /// preset it was launched from (B09; `nil` for an ordinary pane or data
    /// saved before this existed), and whether it held focus at save time.
    /// Reports naming a remote host are dropped by the parser before they
    /// can be saved here, so a directory is always a local path.
    case pane(directory: String?, presetName: String? = nil, isFocused: Bool = false)
    /// - Parameter position: the divider as a *fraction* of the node's axis,
    ///   not points. A restored window may open on a different display, or at
    ///   a size the user changed since; a fraction keeps the proportions the
    ///   user set instead of stranding one pane at its minimum.
    case split(vertical: Bool, position: Double, first: PaneLayout, second: PaneLayout)

    /// The first pane in tree order — the one a restored window's root pane
    /// has to be, since that pane is created before the layout is applied.
    var firstDirectory: String? {
        switch self {
        case .pane(let directory, _, _): return directory
        case .split(_, _, let first, _): return first.firstDirectory
        }
    }

    /// The first pane's preset name, mirroring `firstDirectory` exactly —
    /// `SplitViewController.viewDidLoad()` needs it at the same moment and
    /// for the same reason it needs the directory (B09).
    var firstPresetName: String? {
        switch self {
        case .pane(_, let presetName, _): return presetName
        case .split(_, _, let first, _): return first.firstPresetName
        }
    }

    /// A divider closer to an edge than this leaves a pane too narrow to
    /// hold a prompt; a saved fraction outside the range (or `NaN`) is a
    /// corrupt file, not a preference.
    static let dividerRange: ClosedRange<Double> = 0.05...0.95

    /// The deepest split tree a restore will rebuild. Twelve levels is 4096
    /// panes — far past anything a person arranges by hand, and the point of
    /// the cap is a state file that is *not* hand-made: `PaneLayout` is
    /// recursive, and a truncated or hostile JSON nesting thousands deep
    /// would recurse the decoder and every walk over the tree until the
    /// stack ran out. Below the cap the deeper half becomes a plain pane.
    static let maximumDepth = 12

    /// The same tree with impossible geometry repaired: divider fractions
    /// clamped into `dividerRange` (a non-finite one becomes a centred
    /// split), and nesting past `maximumDepth` collapsed to a single pane.
    ///
    /// A restore reads a file the user can edit and a crash can truncate, so
    /// "the file said so" is not a reason to build a window nobody can use
    /// (U07). Repaired rather than rejected: an arrangement with one silly
    /// divider is still the arrangement the person had.
    func validated(depth: Int = 0) -> PaneLayout {
        switch self {
        case .pane:
            return self
        case .split(let vertical, let position, let first, let second):
            guard depth < Self.maximumDepth else { return .pane(directory: firstDirectory) }
            let clamped =
                position.isFinite
                ? min(max(position, Self.dividerRange.lowerBound), Self.dividerRange.upperBound)
                : 0.5
            return .split(
                vertical: vertical, position: clamped,
                first: first.validated(depth: depth + 1),
                second: second.validated(depth: depth + 1))
        }
    }

    /// The same tree with directories that do not exist locally dropped to
    /// `nil`, which restores as the home directory like a pane that never
    /// reported one.
    ///
    /// State saved before OSC 7 reports were host-filtered can still carry a
    /// directory from a remote machine — by load time the host is gone, so
    /// whether the path names a local directory is the only check left. The
    /// same check covers a directory on a volume that has since been
    /// unmounted.
    func droppingMissingDirectories(fileManager: FileManager = .default) -> PaneLayout {
        switch self {
        case .pane(let directory, let presetName, let isFocused):
            if let directory {
                var isDirectory = ObjCBool(false)
                guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return .pane(directory: nil, presetName: presetName, isFocused: isFocused) }
            }
            return self
        case .split(let vertical, let position, let first, let second):
            return .split(
                vertical: vertical, position: position,
                first: first.droppingMissingDirectories(fileManager: fileManager),
                second: second.droppingMissingDirectories(fileManager: fileManager))
        }
    }
}

nonisolated extension PaneLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case pane, split
    }

    /// Mirrors exactly what Swift's automatic enum-with-associated-values
    /// synthesis produced before this needed a hand-written implementation
    /// — `{"pane": {"directory": ...}}` / `{"split": {...}}` — so state
    /// saved by an older Corta still decodes; `presetName`/`isFocused`
    /// simply weren't keys in that JSON yet.
    private struct PanePayload: Codable {
        var directory: String?
        var presetName: String?
        var isFocused: Bool?
    }

    private struct SplitPayload: Codable {
        var vertical: Bool
        var position: Double
        var first: PaneLayout
        var second: PaneLayout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(PanePayload.self, forKey: .pane) {
            self = .pane(
                directory: pane.directory, presetName: pane.presetName,
                isFocused: pane.isFocused ?? false)
        } else {
            let split = try container.decode(SplitPayload.self, forKey: .split)
            self = .split(
                vertical: split.vertical, position: split.position, first: split.first,
                second: split.second)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let directory, let presetName, let isFocused):
            try container.encode(
                PanePayload(directory: directory, presetName: presetName, isFocused: isFocused),
                forKey: .pane)
        case .split(let vertical, let position, let first, let second):
            try container.encode(
                SplitPayload(vertical: vertical, position: position, first: first, second: second),
                forKey: .split)
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
    static var fileURL: URL { directory.appendingPathComponent("state.json") }

    /// Where the state and its restore marker live. Overridable so a test
    /// can exercise the crash-marker protocol against a real filesystem
    /// without writing into the user's own Application Support (U07).
    nonisolated(unsafe) static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corta")
    }()

    /// The saved windows, oldest first, or an empty array when there is
    /// nothing to restore. A malformed file is treated as no file: a
    /// terminal that refuses to launch because its restore state is corrupt
    /// is worse than one that opens a fresh window. Pane directories are
    /// filtered through `PaneLayout.droppingMissingDirectories` — state
    /// written before OSC 7 reports were host-filtered can still hold a
    /// remote machine's path.
    static func load() -> [WindowState] {
        guard let data = try? Data(contentsOf: fileURL),
            let states = try? JSONDecoder().decode([WindowState].self, from: data)
        else { return [] }
        // B09 — a window saved by a *newer* Corta, in a version this build
        // does not understand, is skipped rather than guessed at: the same
        // "degrade, don't vanish" rule applied per-window instead of to the
        // whole file, now that there is a version to check.
        return states.filter { $0.version <= WindowState.currentVersion }.map {
            WindowState(
                frame: $0.frame,
                layout: $0.layout.validated().droppingMissingDirectories(),
                tabGroupID: $0.tabGroupID, tabIndex: $0.tabIndex, isSelectedTab: $0.isSelectedTab)
        }
    }

    // MARK: - Surviving a crash (U07)

    /// Set while a restore is being applied, cleared once every saved window
    /// is up.
    ///
    /// Without it, "recover the last-known-good layout" and "do not replay a
    /// layout that crashes on restore" are the same file arguing with itself:
    /// the state used to be deleted at launch so a crash could not loop, and
    /// that also meant a crash *after* launch lost the arrangement entirely.
    /// A separate marker separates the two — a crash during restore leaves it
    /// behind and the next launch starts fresh; a crash at any other time
    /// does not, and the debounced state file is still there to restore from.
    static var markerURL: URL { directory.appendingPathComponent("restore-in-progress") }

    /// Whether the previous launch died while applying a restore, in which
    /// case the saved layout is what killed it and is not tried again.
    static var previousRestoreFailed: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func beginRestore() {
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)
    }

    static func endRestore() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// What a launch should do about the saved arrangement.
    ///
    /// Pulled out of `AppDelegate` so the decision can be staged against a
    /// real state directory — a marker left behind by a launch that died is
    /// exactly the state to test, and it is a file, not a crash (U07).
    enum RestoreDecision: Equatable {
        /// The previous launch died while applying a restore.
        case skipAfterFailure
        /// No saved windows.
        case nothingToRestore
        /// Restore these.
        case restore([WindowState])
    }

    static func decideRestore() -> RestoreDecision {
        if previousRestoreFailed { return .skipAfterFailure }
        let states = load()
        return states.isEmpty ? .nothingToRestore : .restore(states)
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
