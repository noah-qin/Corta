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
import CortaTerminal

/// What Space remembers between launches: the project folders and, for each,
/// the sessions to start again and which of them were on screen. Never
/// contents and never a command line: a restored session is a fresh login
/// shell in its directory, the configured preset of that name, or the same
/// SSH destination the connect dialog made.
///
/// App-owned state in Application Support (`CONFIGURATION.md` §8), never a
/// file in the project folder: a folder can come from anyone's repository,
/// and a file there naming sessions would be a way to make Corta start them.
nonisolated struct SpaceState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Bounds on a file that is read back at launch.
    static let maximumProjects = 64
    static let maximumSessions = 32

    var version = SpaceState.currentVersion
    var projects: [SpaceProjectRecord] = []
    /// The project folder last shown.
    var selectedProject: String?

    init(projects: [SpaceProjectRecord] = [], selectedProject: String? = nil) {
        self.projects = projects
        self.selectedProject = selectedProject
    }

    /// The file as Corta can use it: bounded, absolute paths only, every
    /// index and divider in range. A hand-edited or truncated file degrades
    /// field by field rather than as a whole.
    func validated() -> SpaceState {
        var seen = Set<String>()
        let projects = projects.compactMap { project -> SpaceProjectRecord? in
            guard project.path.hasPrefix("/"), seen.insert(project.path).inserted else { return nil }
            return project.validated()
        }
        let kept = Array(projects.prefix(Self.maximumProjects))
        return SpaceState(
            projects: kept,
            selectedProject: kept.contains { $0.path == selectedProject } ? selectedProject : kept.first?.path)
    }
}

nonisolated struct SpaceProjectRecord: Codable, Equatable, Sendable {
    var path: String
    var sessions: [SpaceSessionRecord] = []
    /// The grid: which sessions are on screen, and how they are split.
    var layout: SpaceLayoutRecord?
    /// The next session's number; numbers are never reused within a project,
    /// so a name stays with its session when another one closes.
    var nextNumber = 1

    func validated() -> SpaceProjectRecord {
        let sessions = Array(sessions.prefix(SpaceState.maximumSessions)).map { $0.validated() }
        let highest = sessions.map(\.number).max() ?? 0
        return SpaceProjectRecord(
            path: path, sessions: sessions, layout: layout?.validated(sessionCount: sessions.count),
            nextNumber: min(max(nextNumber, highest + 1), 1_000_000))
    }
}

/// The grid as a value: a panel names a session by its index, a split
/// divides its area between two subtrees at `fraction` of its axis
/// (`vertical`: side by side).
nonisolated indirect enum SpaceLayoutRecord: Codable, Equatable, Sendable {
    case panel(Int)
    case split(vertical: Bool, fraction: Double, first: SpaceLayoutRecord, second: SpaceLayoutRecord)

    /// The sessions on screen, in reading order.
    var panels: [Int] {
        switch self {
        case .panel(let index): return [index]
        case .split(_, _, let first, let second): return first.panels + second.panels
        }
    }

    /// Only existing sessions, each once, at most `SpaceGrid.maximumPanels`,
    /// fractions in range; a split that loses a side becomes the other.
    func validated(sessionCount: Int) -> SpaceLayoutRecord? {
        var seen = Set<Int>()
        return pruned(sessionCount: sessionCount, seen: &seen, depth: 0)
    }

    private func pruned(sessionCount: Int, seen: inout Set<Int>, depth: Int) -> SpaceLayoutRecord? {
        switch self {
        case .panel(let index):
            guard (0..<sessionCount).contains(index), seen.count < SpaceGrid.maximumPanels,
                  seen.insert(index).inserted else { return nil }
            return self
        case .split(let vertical, let fraction, let first, let second):
            guard depth < SpaceGrid.maximumPanels else { return nil }
            let left = first.pruned(sessionCount: sessionCount, seen: &seen, depth: depth + 1)
            let right = second.pruned(sessionCount: sessionCount, seen: &seen, depth: depth + 1)
            guard let left else { return right }
            guard let right else { return left }
            let clamped = fraction.isFinite
                ? min(max(fraction, SpaceGrid.dividerRange.lowerBound), SpaceGrid.dividerRange.upperBound) : 0.5
            return .split(vertical: vertical, fraction: clamped, first: left, second: right)
        }
    }

    /// Up to six panels in at most two lines: in columns, each column a
    /// stack with its own heights; in rows, each row a line with its own
    /// widths. Every split even.
    static func arranged(_ panels: [Int], inColumns: Bool) -> SpaceLayoutRecord? {
        guard !panels.isEmpty else { return nil }
        let lines = panels.count > 3 ? 2 : 1
        let perGroup = Int((Double(panels.count) / Double(lines)).rounded(.up))
        // Columns hold the lines' panels one above the other; rows, side by side.
        let groupCount = inColumns ? perGroup : lines
        let groupSize = inColumns ? lines : perGroup
        var groups: [[Int]] = []
        var rest = panels[...]
        for remaining in stride(from: groupCount, to: 0, by: -1) {
            let size = min(groupSize, max(1, rest.count - (remaining - 1)))
            groups.append(Array(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        func chain(_ items: [SpaceLayoutRecord], vertical: Bool) -> SpaceLayoutRecord? {
            guard let first = items.first else { return nil }
            guard let rest = chain(Array(items.dropFirst()), vertical: vertical) else { return first }
            return .split(vertical: vertical, fraction: 1 / Double(items.count), first: first, second: rest)
        }
        let built = groups.compactMap { chain($0.map(SpaceLayoutRecord.panel), vertical: !inColumns) }
        return chain(built, vertical: inColumns)
    }

    /// Each panel's size when the layout fills `area`: what its session
    /// starts at.
    func panelSizes(in area: CGSize) -> [Int: CGSize] {
        switch self {
        case .panel(let index): return [index: area]
        case .split(let vertical, let fraction, let first, let second):
            let gap = SpaceGrid.dividerThickness
            let extent = vertical ? area.width : area.height
            let lead = (extent * CGFloat(fraction)).rounded()
            let trail = max(0, extent - lead - gap)
            let firstArea = vertical
                ? CGSize(width: lead, height: area.height) : CGSize(width: area.width, height: lead)
            let secondArea = vertical
                ? CGSize(width: trail, height: area.height) : CGSize(width: area.width, height: trail)
            return first.panelSizes(in: firstArea).merging(second.panelSizes(in: secondArea)) { old, _ in old }
        }
    }
}

nonisolated struct SpaceSessionRecord: Codable, Equatable, Sendable {
    var conversation: LocalConversation?
    var number: Int
    /// The local working directory at the last save; nil for a remote one.
    var directory: String?
    /// A configured preset, resolved by name against the current config.
    var presetName: String?
    /// The connect dialog's destination, re-validated when read.
    var ssh: SSHTarget?
    /// The user's name for it, which programs' titles never replace.
    var name: String?

    init(number: Int, directory: String? = nil, presetName: String? = nil, ssh: SSHTarget? = nil) {
        self.number = number
        self.directory = directory
        self.presetName = presetName
        self.ssh = ssh
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, number, directory, presetName, ssh, name
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversation = nil
        if let saved = try? values.nestedContainer(keyedBy: ConversationKeys.self, forKey: .conversation),
           let kind = try? saved.decode(LocalConversation.Kind.self, forKey: .kind),
           let raw = try? saved.decode(String.self, forKey: .id),
           let uuid = LocalConversation.standardUUID(raw) {
            conversation = LocalConversation(kind: kind, id: uuid)
        }
        number = try values.decode(Int.self, forKey: .number)
        directory = try values.decodeIfPresent(String.self, forKey: .directory)
        presetName = try values.decodeIfPresent(String.self, forKey: .presetName)
        ssh = try values.decodeIfPresent(SSHTarget.self, forKey: .ssh)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        if ssh != nil { conversation = nil }
    }

    private enum ConversationKeys: String, CodingKey { case kind, id }

    static let maximumNameLength = 64

    /// A typed or stored name as a row can show it: one line, no controls,
    /// bounded; nil when nothing is left.
    static func cleanName(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : String(clean.prefix(maximumNameLength))
    }

    func validated() -> SpaceSessionRecord {
        var record = self
        record.number = min(max(number, 1), 1_000_000)
        record.name = Self.cleanName(name)
        if let directory, !directory.hasPrefix("/") { record.directory = nil }
        if let ssh {
            record.conversation = nil
            // The key file is checked when connecting, as for a recent host.
            let parsed = SSHTarget.parse(
                host: ssh.host, user: ssh.user ?? "", port: ssh.port.map(String.init) ?? "",
                identityFile: ssh.identityFile ?? "", checkingFiles: false)
            record.ssh = try? parsed.get()
        }
        return record
    }
}

/// The grid's rules, on plain values so they are testable without a window.
///
/// The grid is a free split tree, as the terminal mode's is: a session
/// dropped on a panel's edge splits it there, one dropped on its middle
/// takes its place. A split is never made that would leave a panel smaller
/// than `minimumGrid` cells, and the grid holds at most `space-panel-limit`
/// panels.
nonisolated enum SpaceGrid {
    static let maximumPanels = 6
    /// Below this a full-screen tool — an agent's TUI, an editor — starts to
    /// wrap and truncate. Not 80 × 24: on a 14-inch display beside the
    /// sidebar that allows one panel, and the grid would never be one.
    static let minimumGrid = (columns: 64, rows: 18)
    /// The gap between panel cards, which is also where a divider drags.
    static let dividerThickness: CGFloat = 8
    static let dividerRange = 0.1...0.9
    /// How far into a panel, as a share of its side, a drop means its edge.
    static let edgeBand: CGFloat = 0.25

    enum Edge: Equatable, Sendable {
        case left, right, top, bottom

        /// Side by side, rather than stacked.
        var isVertical: Bool { self == .left || self == .right }
        /// The new panel comes first: left or above.
        var isLeading: Bool { self == .left || self == .top }
    }

    /// The edge a drop at `point` means, in a panel of `size` (y up), or nil
    /// for its middle. The nearest edge wins inside the band.
    static func edge(at point: CGPoint, in size: CGSize) -> Edge? {
        guard size.width > 0, size.height > 0 else { return nil }
        let candidates: [(Edge, CGFloat)] = [
            (.left, point.x / size.width), (.right, 1 - point.x / size.width),
            (.bottom, point.y / size.height), (.top, 1 - point.y / size.height),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < edgeBand else { return nil }
        return nearest.0
    }

    /// Whether a panel of `size` can split that way and leave both halves
    /// at least `minimum`.
    static func canSplit(_ size: CGSize, vertical: Bool, minimum: CGSize) -> Bool {
        vertical
            ? size.width >= minimum.width * 2 + dividerThickness
            : size.height >= minimum.height * 2 + dividerThickness
    }

    /// How a panel of `size` splits for a new session placed automatically:
    /// along its roomier axis, in units of the minimum; nil if neither way
    /// leaves two panels of the minimum.
    static func automaticSplit(of size: CGSize, minimum: CGSize) -> Bool? {
        let wide = size.width / max(minimum.width, 1) >= size.height / max(minimum.height, 1)
        if canSplit(size, vertical: wide, minimum: minimum) { return wide }
        if canSplit(size, vertical: !wide, minimum: minimum) { return !wide }
        return nil
    }

    /// The panel least recently used, other than `protected`; the focused
    /// one only if it is the only one.
    static func leastRecentlyUsed<ID: Equatable>(_ panels: [ID], recency: (ID) -> UInt64, protected: ID?) -> ID? {
        let pool = panels.filter { $0 != protected }
        return (pool.isEmpty ? panels : pool).min { recency($0) < recency($1) }
    }
}

/// Reads and writes `space.json` in Application Support, owner-only.
@MainActor
struct SpaceStore {
    let directory: URL

    static let standard = SpaceStore(directory: AppPaths.applicationSupportDirectory)

    var fileURL: URL { directory.appendingPathComponent("space.json") }

    /// The saved state, validated, without projects whose folder is gone. A
    /// malformed or newer file counts as empty and is not written over.
    func load(
        isDirectory: @escaping @Sendable (String) -> Bool = PathProbe.isDirectory
    ) -> SpaceState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SpaceState.self, from: data),
              state.version <= SpaceState.currentVersion
        else { return SpaceState() }
        var valid = state.validated()
        if SpaceConversationJSON.hasDuplicateKeys(data) {
            for project in valid.projects.indices {
                for session in valid.projects[project].sessions.indices {
                    valid.projects[project].sessions[session].conversation = nil
                }
            }
        }
        // Bounded, off the main thread: a project on a mount that stopped
        // answering must not hold the window.
        let existing = PathProbe.directories(
            among: valid.projects.map(\.path) + valid.projects.flatMap { $0.sessions.compactMap(\.directory) },
            timeout: SessionRestore.directoryCheckTimeout, isDirectory: isDirectory)
        valid.projects = valid.projects.filter { existing.contains($0.path) }.map { project in
            var project = project
            for index in project.sessions.indices {
                if let directory = project.sessions[index].directory, !existing.contains(directory) {
                    project.sessions[index].directory = nil
                }
            }
            return project
        }
        return valid.validated()
    }

    func save(_ state: SpaceState) {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(VersionProbe.self, from: data),
           (saved.version ?? 0) > SpaceState.currentVersion { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Owner-only, as `state.json`: folders say where you work.
        try? PrivateFile.write(data, to: fileURL)
    }

    private struct VersionProbe: Decodable { var version: Int? }
}
