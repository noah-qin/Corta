// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// What a window was, in enough detail to open it again: the arrangement
/// (windows, splits, dividers, directories), never the contents. A
/// scrollback without its process is a screenshot pretending to be a
/// session.
nonisolated struct WindowState: Equatable, Sendable {
    /// Bumped when the saved shape changes beyond what `decodeIfPresent`
    /// absorbs. Absent in older data, hence the `0` default.
    static let currentVersion = 1

    var version: Int
    /// `TerminalWindowController.windowID`, so an App Intent's identity
    /// survives a relaunch; nil in older data mints a fresh one.
    var id: String?
    var frame: Frame
    var layout: PaneLayout
    /// `NSWindow.tabbingIdentifier`, to regroup tabs on restore.
    var tabGroupID: String?
    /// Position in the tab group, oldest first.
    var tabIndex: Int?
    /// Frontmost in its group; decodes `true` for untabbed or older data.
    var isSelectedTab: Bool
    var customTabTitle: String?

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

        static let minimumSize = CGSize(width: 320, height: 200)
        static let defaultSize = CGSize(width: 900, height: 560)

        var isUsable: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && width >= Self.minimumSize.width && height >= Self.minimumSize.height
        }

        /// The saved rect moved and shrunk onto a display that exists now.
        /// Saved origins can name a point no display covers after an
        /// unplug, and AppKit doesn't correct a programmatic frame. Picks
        /// the screen overlapped most (else main), clamps to its
        /// `visibleFrame` (clear of menu bar and Dock), and checks for
        /// zero, negative or NaN sizes first, since `min`/`max` propagate
        /// NaN.
        func onScreen(_ screens: [NSScreen] = NSScreen.screens, preferredScreen: NSScreen? = nil, minimumSize: CGSize = WindowState.Frame.minimumSize) -> NSRect {
            fitting(visibleFrames: screens.map(\.visibleFrame),
                    preferredFrame: preferredScreen?.visibleFrame ?? (screens.isEmpty ? NSScreen.main?.visibleFrame : nil),
                    minimumSize: minimumSize)
        }

        /// Geometry-only path for Dock and multi-display regression fixtures.
        func fitting(visibleFrames: [NSRect], preferredFrame: NSRect? = nil, minimumSize: CGSize = WindowState.Frame.minimumSize) -> NSRect {
            let valid = x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && width > 0 && height > 0 && width >= minimumSize.width && height >= minimumSize.height
            let saved = valid ? rect : NSRect(
                origin: x.isFinite && y.isFinite ? rect.origin : .zero,
                size: Self.defaultSize)
            let target = preferredFrame ?? visibleFrames.max(by: {
                $0.intersection(saved).area < $1.intersection(saved).area
            })
            guard let visible = target, !visible.isEmpty else { return saved }
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
        case version, id, frame, layout, tabGroupID, tabIndex, isSelectedTab, customTabTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        id = try container.decodeIfPresent(String.self, forKey: .id)
        customTabTitle = try container.decodeIfPresent(String.self, forKey: .customTabTitle)
        frame = try container.decode(Frame.self, forKey: .frame)
        layout = try container.decode(PaneLayout.self, forKey: .layout)
        tabGroupID = try container.decodeIfPresent(String.self, forKey: .tabGroupID)
        tabIndex = try container.decodeIfPresent(Int.self, forKey: .tabIndex)
        isSelectedTab = try container.decodeIfPresent(Bool.self, forKey: .isSelectedTab) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(customTabTitle, forKey: .customTabTitle)
        try container.encode(frame, forKey: .frame)
        try container.encode(layout, forKey: .layout)
        try container.encodeIfPresent(tabGroupID, forKey: .tabGroupID)
        try container.encodeIfPresent(tabIndex, forKey: .tabIndex)
        try container.encode(isSelectedTab, forKey: .isSelectedTab)
    }
}

extension NSRect {
    /// Zero for the null rect a non-overlapping `intersection` returns.
    fileprivate nonisolated var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}

/// The split tree as a value, mirroring `SplitTree`.
nonisolated indirect enum PaneLayout: Equatable, Sendable {
    /// A pane: its last OSC 7 directory (always local; remote reports become
    /// `RemoteContext`), its preset, and whether it had focus.
    case pane(directory: String?, presetName: String? = nil, isFocused: Bool = false)
    /// - Parameter position: the divider as a fraction, so proportions hold
    ///   on another display or window size.
    case split(vertical: Bool, position: Double, first: PaneLayout, second: PaneLayout)

    /// The first pane in tree order: the root pane, created before the layout
    /// is applied.
    var firstDirectory: String? {
        switch self {
        case .pane(let directory, _, _): return directory
        case .split(_, _, let first, _): return first.firstDirectory
        }
    }

    /// As `firstDirectory`, for the preset.
    var firstPresetName: String? {
        switch self {
        case .pane(_, let presetName, _): return presetName
        case .split(_, _, let first, _): return first.firstPresetName
        }
    }

    /// Outside this a pane can't hold a prompt; such a value is corruption.
    static let dividerRange: ClosedRange<Double> = 0.05...0.95

    /// The deepest tree restored (4096 panes). A hostile or truncated file
    /// nested thousands deep would exhaust the stack in the recursive decode
    /// and walks; below the cap the deeper half becomes a pane.
    static let maximumDepth = 12

    /// Repairs impossible geometry: clamps dividers (non-finite centres) and
    /// collapses nesting past `maximumDepth`. Repaired, not rejected: one bad
    /// divider is still the user's arrangement.
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

    /// Drops directories that don't exist locally (a remote path from before
    /// host filtering, an unmounted volume) to nil, which restores home.
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

    /// Matches the JSON Swift's synthesis used to produce, so older state
    /// still decodes; newer keys are optional.
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

/// Reads and writes the saved arrangement in Application Support, not the
/// config file: it is state, not settings, and would churn the file on
/// every move. `restore-windows = false` stops reads and writes alike.
@MainActor
enum SessionRestore {
    static var fileURL: URL { directory.appendingPathComponent("state.json") }

    /// Overridable so tests don't touch the user's Application Support.
    nonisolated(unsafe) static var directory: URL = AppPaths.applicationSupportDirectory

    /// The saved windows, oldest first. A malformed file counts as none:
    /// better a fresh window than a terminal that won't launch.
    static func load() -> [WindowState] {
        guard let data = try? Data(contentsOf: fileURL),
            let states = try? JSONDecoder().decode([WindowState].self, from: data)
        else { return [] }
        // Skip windows from a newer format rather than guess.
        return states.filter { $0.version <= WindowState.currentVersion }.map { saved in
            var state = saved
            state.layout = saved.layout.validated().droppingMissingDirectories()
            return state
        }
    }

    // MARK: - Surviving a crash

    /// Present only while a restore is applied. A crash during restore leaves
    /// it, and the next launch starts fresh; a crash at any other time leaves
    /// the debounced state to restore from.
    static var markerURL: URL { directory.appendingPathComponent("restore-in-progress") }

    /// The previous launch died mid-restore; that layout is not retried.
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

    /// What a launch does with the saved arrangement; separate from
    /// `AppDelegate` so a leftover marker can be tested as a file.
    enum RestoreDecision: Equatable {
        case skipAfterFailure
        case nothingToRestore
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
