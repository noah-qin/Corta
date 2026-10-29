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

/// One session of a project. The pane exists once the project has been
/// opened this launch; before that the record says what to start.
@MainActor
final class SpaceSession {
    var id: UUID { record.id }
    var record: SpaceSessionRecord
    var pane: ViewController?
    /// `CortaSpaceController.touch` order: the grid replaces the lowest.
    var lastUsed: UInt64 = 0
    /// A successful off-grid fill is explained when its panel first shows.
    var conversationNeedsNotice = false
    /// Transient expected input for the delayed notice; never persisted.
    var conversationFilledCommand: String?
    var conversationFilledPrompt: (row: Int, column: Int)?
    var conversationObservation: ConversationObservation?

    init(record: SpaceSessionRecord) {
        self.record = record
    }

    var number: Int { record.number }

    /// The record as it should be saved: a local session's directory is
    /// where its shell is now.
    var currentRecord: SpaceSessionRecord {
        var record = record
        if record.ssh == nil, let directory = pane?.session?.workingDirectory { record.directory = directory }
        return record
    }
}

extension SpaceSession: Hashable {
    /// Identity: two records alike are still two sessions. Hashable too,
    /// because the sidebar's outline asks its items for `-hash`.
    nonisolated static func == (lhs: SpaceSession, rhs: SpaceSession) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension SpaceProject: Hashable {
    nonisolated static func == (lhs: SpaceProject, rhs: SpaceProject) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A folder and its sessions, while this window's Space holds them.
@MainActor
final class SpaceProject {
    let url: URL
    var sessions: [SpaceSession]
    /// The grid: a free split tree of panels (`SpacePaneView`), kept while
    /// another project shows so it comes back exactly as it was.
    var tree: SplitTree?
    /// The saved grid, until the project is first shown and it is built.
    var pendingLayout: SpaceLayoutRecord?
    var nextNumber: Int
    weak var focused: SpaceSession?
    /// The panel filling the grid, if one does, and where it came from.
    weak var maximized: SpaceSession?
    var maximizeOrigin: MaximizeOrigin?

    /// Where a filled panel goes back to, and the grid's shape before.
    struct MaximizeOrigin {
        let split: NSSplitView
        let index: Int
        let layout: SpaceLayoutRecord?
    }
    /// Its sessions run: they start the first time the project is shown in a
    /// launch, not at launch, so a list of old projects costs nothing.
    var isStarted = false
    var conversationPreparation: Task<Void, Never>?

    init(record: SpaceProjectRecord) {
        url = URL(fileURLWithPath: record.path, isDirectory: true)
        let sessions = record.sessions.map(SpaceSession.init)
        self.sessions = sessions
        pendingLayout = record.layout
        nextNumber = record.nextNumber
        focused = record.layout?.panels.first.map { sessions[$0] }
    }

    var path: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }

    /// On screen, in reading order — the filled panel included.
    var shown: [SpaceSession] {
        var panels = tree?.leaves.compactMap { ($0 as? SpacePaneView)?.session } ?? []
        if let maximized, !panels.contains(maximized) { panels.append(maximized) }
        return panels
    }

    var record: SpaceProjectRecord {
        SpaceProjectRecord(path: path, sessions: sessions.map(\.currentRecord), layout: layout, nextNumber: nextNumber)
    }

    /// The grid as it is on screen, or as it was saved if not built yet.
    var layout: SpaceLayoutRecord? {
        if let origin = maximizeOrigin { return origin.layout }
        guard let root = tree?.root else { return pendingLayout }
        return capture(root)
    }

    private func capture(_ view: NSView) -> SpaceLayoutRecord? {
        if let split = view as? NSSplitView, split.subviews.count == 2 {
            let axis = split.isVertical ? split.bounds.width : split.bounds.height
            let first = split.subviews[0].frame
            let extent = split.isVertical ? first.width : first.height
            let lead = capture(split.subviews[0]), trail = capture(split.subviews[1])
            guard let lead, let trail else { return lead ?? trail }
            return .split(vertical: split.isVertical, fraction: axis > 0 ? Double(extent / axis) : 0.5,
                          first: lead, second: trail)
        }
        guard let panel = view as? SpacePaneView,
              let index = sessions.firstIndex(where: { $0 === panel.session }) else { return nil }
        return .panel(index)
    }

    /// The sessions waiting on the user, for the sidebar's badge.
    var attentionCount: Int {
        sessions.filter { SpaceSessionPresentation(session: $0).needsAttention }.count
    }
}

/// What a session's chrome says. Only facts the pane already has, each one
/// sanitised where it came from: the agent status the terminal reported
/// (`PaneAgents`), the foreground program the kernel names, the SSH
/// destination the connect dialog made, the directory the kernel confirms.
@MainActor
struct SpaceSessionPresentation: Equatable {
    /// A program's own name for itself, the program, the host — else
    /// "Terminal N" for a shell at its prompt.
    let title: String
    /// Where it is: the directory, or the remote host.
    let detail: String
    let state: String?
    let symbol: String
    let tint: NSColor?
    let needsAttention: Bool
    let isRunning: Bool

    init(session: SpaceSession) {
        let fallback = L10n.format("space.session.number", session.number)
        let host = session.record.ssh?.displayName
        guard let pane = session.pane else {
            // Not started yet: the project has not been opened this launch.
            isRunning = false
            title = session.record.name ?? host ?? fallback
            detail = host == nil
                ? (session.record.directory.map(PaneWindowTitle.abbreviated) ?? fallback)
                : L10n.text("space.session.remote")
            state = L10n.text("space.state.notStarted")
            symbol = host == nil ? Self.localSymbol : Self.remoteSymbol
            tint = nil
            needsAttention = false
            return
        }
        isRunning = true
        let remote: Bool
        switch pane.remote.state {
        case .remote, .remoteUnknown, .connected: remote = true
        default: remote = host != nil
        }
        // What kind of session it is: a program reporting as an agent (or
        // detected as one) outranks where it runs.
        symbol = pane.agents.status != nil ? Self.agentSymbol : remote ? Self.remoteSymbol : Self.localSymbol
        let status = ConfigurationStore.shared.configuration.agentStatus ? pane.agents.status : nil
        let program = pane.session?.foregroundProcessName
        title = session.record.name ?? PaneWindowTitle.sanitizedTitleComponent(status?.app) ?? host
            ?? PaneWindowTitle.sanitizedTitleComponent(program) ?? fallback
        detail = remote
            ? (host ?? L10n.text("space.session.remote"))
            : (pane.session?.currentDirectory.map(PaneWindowTitle.abbreviated) ?? "")
        let shown = Self.state(of: pane, status: status, program: program)
        (state, tint, needsAttention) = (shown.text, shown.tint, shown.needsAttention)
    }

    /// One symbol per kind of session; no product's own mark.
    static let localSymbol = "terminal"
    static let remoteSymbol = "server.rack"
    static let agentSymbol = "sparkles"

    private struct State {
        var text: String?
        var tint: NSColor?
        var needsAttention = false
    }

    /// Ended, the agent's own state, a program running, or nothing to say.
    private static func state(
        of pane: ViewController, status: ProgramStatus?, program: String?
    ) -> State {
        if pane.sessionEndedPanel != nil {
            return State(text: L10n.text("space.state.ended"), tint: .secondaryLabelColor)
        }
        if let status {
            let tint: NSColor
            switch status.state {
            case .working: tint = .systemGreen
            case .blocked: tint = .systemOrange
            case .error: tint = .systemRed
            case .done: tint = .systemBlue
            case .idle, .unknown: tint = .tertiaryLabelColor
            }
            return State(text: L10n.text("agent.state." + status.state.rawValue), tint: tint,
                         needsAttention: status.state == .blocked || status.state == .error)
        }
        if program != nil { return State(text: L10n.text("space.state.running"), tint: .systemGreen) }
        return State()
    }
}
