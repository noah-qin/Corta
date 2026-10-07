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

import Observation

/// The command palette's state and filtering, as `CommandPaletteView`
/// binds to it.
///
/// It owns no command list of its own — it filters `TerminalCommand
/// .allCases`, the same table the menus and the keybindings read, so a
/// command added there appears here for free. Running a command goes through
/// `onRun`, set by `CommandPaletteController` to close the panel and dispatch
/// through the responder chain (`NSApp.sendAction`) exactly the way a menu
/// item does — the model itself knows nothing about `NSApp` or windows.
@MainActor
@Observable
final class CommandPaletteModel {
    /// A group heading or a command. Headings are non-selectable and skipped
    /// by the arrow keys, so the list reads as sections without the
    /// selection ever landing on one.
    ///
    /// A command run recently is listed twice while browsing — under Recent
    /// and in its group — so a row's identity is its section as well as its
    /// command. Keyed by command alone, the two rows shared one SwiftUI id,
    /// both lit up, and stepping down onto the second jumped back to the
    /// first: the arrow keys could never get past it.
    enum Row: Identifiable, Equatable {
        case header(String)
        case command(TerminalCommand, recent: Bool, shortcut: String)

        var id: String {
            switch self {
            case .header(let title): "header-\(title)"
            case .command(let command, let recent, _):
                (recent ? "recent-" : "command-") + command.rawValue
            }
        }

        var command: TerminalCommand? {
            if case .command(let command, _, _) = self { command } else { nil }
        }
    }

    /// Rebuilds `rows`, once per change rather than once per read: the view,
    /// the selection check and the arrow keys all read them.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // A new query starts at its best match, and an emptied one at
            // the top — not wherever the last list's selection happens to
            // recur further down.
            selectedRowID = nil
            rebuildRows()
        }
    }
    /// What the list shows, kept in step with `query` and the recents.
    private(set) var rows: [Row] = []
    /// The selected row's `id`, not its command, for the reason `Row` gives.
    private(set) var selectedRowID: String?
    var onRun: ((TerminalCommand) -> Void)?
    var onDismiss: (() -> Void)?

    var selectedCommand: TerminalCommand? {
        selectedRowID.flatMap { id in rows.first { $0.id == id } }?.command
    }

    /// The commands run from the palette, most recent first, deduplicated.
    ///
    /// In memory and for this launch only — deliberately not a config-file
    /// key. The config file is the user's settings, and a most-recently-used
    /// list is neither a setting nor something anyone would hand-edit; a key
    /// for it would be a key `docs/CONFIGURATION.md` has to document and
    /// nobody would ever set.
    private var recentCommands: [TerminalCommand] = []

    private static let recentLimit = 5

    init() {
        rebuildRows()
    }

    /// Re-opened with a clean query and the top row selected — a palette
    /// remembered from last time it closed would show a stale filter. Also
    /// where a rebind made since the last opening reaches the shortcuts.
    func reset() {
        selectedRowID = nil
        if query.isEmpty { rebuildRows() } else { query = "" }
    }

    /// If the current selection fell out of `rows` (the query changed
    /// underneath it), lands on the first command row instead of leaving the
    /// selection on nothing, or on a row that no longer exists.
    func selectFirstIfNeeded() {
        if let selectedRowID, rows.contains(where: { $0.id == selectedRowID }) { return }
        selectedRowID = rows.first { $0.command != nil }?.id
    }

    /// Subsequence matching, which is what people mean by "fuzzy" here:
    /// `spr` finds "Split Pane Right". Ranked so that a match on consecutive
    /// characters, or one starting at a word boundary, beats a scattered one.
    private func rebuildRows() {
        let shortcuts = ConfigurationStore.shared.configuration.keybindings
        func row(_ command: TerminalCommand, recent: Bool = false) -> Row {
            .command(command, recent: recent, shortcut: shortcuts[command]?.displayText ?? "")
        }
        rows =
            query.isEmpty
            ? browsingRows(row: row) : searchRows(matching: query.lowercased(), row: row)
        selectFirstIfNeeded()
    }

    /// With no query: what was used recently, then every command under its
    /// group heading. Recents first because the single most likely next
    /// command is one of the last few — and it is the only ordering that
    /// gets shorter with use rather than longer.
    private func browsingRows(row: (TerminalCommand, Bool) -> Row) -> [Row] {
        var rows: [Row] = []
        let recents = recentCommands.prefix(Self.recentLimit)
        if !recents.isEmpty {
            rows.append(.header(L10n.text("commandPalette.category.recent")))
            rows.append(contentsOf: recents.map { row($0, true) })
        }
        for category in CommandCategory.allCases {
            let commands = TerminalCommand.allCases
                .filter { $0.category == category }
                .sorted { $0.paletteRank < $1.paletteRank }
            guard !commands.isEmpty else { continue }
            rows.append(.header(category.title))
            rows.append(contentsOf: commands.map { row($0, false) })
        }
        return rows
    }

    /// With a query: one flat ranked list, no headings. A search result is
    /// already ordered by how well it matched, and grouping would fight that
    /// ordering for the sake of a structure the user has stopped browsing.
    ///
    /// The title ranks first; the command's config name (`split-right`,
    /// English whatever the interface language) and its group's name also
    /// match, a step below, so "pane" finds every pane command and an
    /// English abbreviation works in a localized interface.
    private func searchRows(matching query: String, row: (TerminalCommand, Bool) -> Row) -> [Row] {
        let categoryTitles = Dictionary(
            uniqueKeysWithValues: CommandCategory.allCases.map { ($0, $0.title.lowercased()) })
        return TerminalCommand.allCases
            .compactMap { command -> (command: TerminalCommand, onTitle: Bool, score: Int)? in
                let onTitle = Self.score(command.title.lowercased(), query: query)
                // Only when the title missed: most keystrokes need none of it.
                guard
                    let score = onTitle
                        ?? [
                            command.rawValue,
                            String(command.rawValue.map { $0 == "-" ? " " : $0 }),
                            categoryTitles[command.category] ?? "",
                        ].compactMap({ Self.score($0, query: query) }).max()
                else { return nil }
                // A recently used command wins a tie against one that has
                // never been run, which is the same argument as the recents
                // section, applied inside the ranking.
                let recency =
                    recentCommands.firstIndex(of: command)
                    .map { Self.recentLimit - $0 } ?? 0
                return (command, onTitle != nil, score + recency)
            }
            // A title match leads whatever the scores: they grow with the
            // query, so no fixed penalty could keep the two apart.
            .sorted { ($0.onTitle ? 1 : 0, $0.score) > ($1.onTitle ? 1 : 0, $1.score) }
            .map { row($0.command, false) }
    }

    /// Pure, and deliberately not `@MainActor`: the ranking is the part worth
    /// testing, and a scoring function that needs a window to run is one
    /// nobody tests.
    nonisolated static func score(_ candidate: String, query: String) -> Int? {
        var score = 0
        var previousIndex: Int?
        var searchIndex = candidate.startIndex
        let characters = Array(candidate)
        for character in query {
            guard let found = candidate[searchIndex...].firstIndex(of: character) else {
                return nil
            }
            let offset = candidate.distance(from: candidate.startIndex, to: found)
            // Adjacent to the previous match, or at the start of a word:
            // both are what a person is picturing when they type an
            // abbreviation.
            if previousIndex == offset - 1 { score += 3 }
            if offset == 0 || characters[offset - 1] == " " { score += 2 }
            previousIndex = offset
            searchIndex = candidate.index(after: found)
        }
        // Shorter titles win ties: "Copy" should beat "Copy on Select".
        return score * 100 - candidate.count
    }

    /// Steps to the next *command* row, stepping over headings rather than
    /// selecting them — a heading is a label, and an arrow key that lands on
    /// one leaves Return with nothing to run.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        var index = selectedRowID.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        var remaining = abs(delta)
        let step = delta > 0 ? 1 : -1
        while remaining > 0 {
            var next = index + step
            while next >= 0, next < rows.count, rows[next].command == nil { next += step }
            guard next >= 0, next < rows.count else { break }
            index = next
            remaining -= 1
        }
        guard index >= 0, index < rows.count, rows[index].command != nil else { return }
        selectedRowID = rows[index].id
    }

    func select(_ row: Row) {
        guard row.command != nil else { return }
        selectedRowID = row.id
    }

    func runSelected() {
        guard let selectedCommand else { return }
        recentCommands.removeAll { $0 == selectedCommand }
        recentCommands.insert(selectedCommand, at: 0)
        onRun?(selectedCommand)
    }

    func dismiss() {
        onDismiss?()
    }
}
