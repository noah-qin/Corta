import Observation

/// M7.12 — the command palette's state and filtering, as `CommandPaletteView`
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
    enum Row: Identifiable, Equatable {
        case header(String)
        case command(TerminalCommand)

        var id: String {
            switch self {
            case .header(let title): "header-\(title)"
            case .command(let command): "command-\(command.rawValue)"
            }
        }

        var command: TerminalCommand? {
            if case .command(let command) = self { command } else { nil }
        }
    }

    var query = ""
    var selectedCommand: TerminalCommand?
    var onRun: ((TerminalCommand) -> Void)?
    var onDismiss: (() -> Void)?

    /// The commands run from the palette, most recent first, deduplicated.
    ///
    /// In memory and for this launch only — deliberately not a config-file
    /// key. The config file is the user's settings, and a most-recently-used
    /// list is neither a setting nor something anyone would hand-edit; a key
    /// for it would be a key `docs/CONFIGURATION.md` has to document and
    /// nobody would ever set.
    private var recentCommands: [TerminalCommand] = []

    private static let recentLimit = 5

    /// Subsequence matching, which is what people mean by "fuzzy" here:
    /// `spr` finds "Split Pane Right". Ranked so that a match on consecutive
    /// characters, or one starting at a word boundary, beats a scattered one.
    var rows: [Row] {
        query.isEmpty ? browsingRows() : searchRows(matching: query.lowercased())
    }

    /// Re-opened with a clean query and the top row selected — a palette
    /// remembered from last time it closed would show a stale filter.
    func reset() {
        query = ""
        selectFirstIfNeeded()
    }

    /// If the current selection fell out of `rows` (the query changed
    /// underneath it), lands on the first command row instead of leaving the
    /// selection on nothing, or on a row that no longer exists.
    func selectFirstIfNeeded() {
        if let selectedCommand, rows.contains(where: { $0.command == selectedCommand }) { return }
        selectedCommand = rows.first { $0.command != nil }?.command
    }

    /// With no query: what was used recently, then every command under its
    /// group heading. Recents first because the single most likely next
    /// command is one of the last few — and it is the only ordering that
    /// gets shorter with use rather than longer.
    private func browsingRows() -> [Row] {
        var rows: [Row] = []
        let recents = recentCommands.prefix(Self.recentLimit)
        if !recents.isEmpty {
            rows.append(.header(L10n.text("commandPalette.category.recent")))
            rows.append(contentsOf: recents.map { Row.command($0) })
        }
        for category in CommandCategory.allCases {
            let commands = TerminalCommand.allCases
                .filter { $0.category == category }
                .sorted { $0.paletteRank < $1.paletteRank }
            guard !commands.isEmpty else { continue }
            rows.append(.header(category.title))
            rows.append(contentsOf: commands.map { Row.command($0) })
        }
        return rows
    }

    /// With a query: one flat ranked list, no headings. A search result is
    /// already ordered by how well it matched, and grouping would fight that
    /// ordering for the sake of a structure the user has stopped browsing.
    private func searchRows(matching query: String) -> [Row] {
        TerminalCommand.allCases
            .compactMap { command -> (TerminalCommand, Int)? in
                guard let score = Self.score(command.title.lowercased(), query: query)
                else { return nil }
                // A recently used command wins a tie against one that has
                // never been run, which is the same argument as the recents
                // section, applied inside the ranking.
                let recency =
                    recentCommands.firstIndex(of: command)
                    .map { Self.recentLimit - $0 } ?? 0
                return (command, score + recency)
            }
            .sorted { $0.1 > $1.1 }
            .map { Row.command($0.0) }
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
        let allRows = rows
        guard !allRows.isEmpty else { return }
        var index =
            selectedCommand.flatMap { command in allRows.firstIndex { $0.command == command } }
            ?? -1
        var remaining = abs(delta)
        let step = delta > 0 ? 1 : -1
        while remaining > 0 {
            var next = index + step
            while next >= 0, next < allRows.count, allRows[next].command == nil { next += step }
            guard next >= 0, next < allRows.count else { break }
            index = next
            remaining -= 1
        }
        guard index >= 0, index < allRows.count, let command = allRows[index].command else {
            return
        }
        selectedCommand = command
    }

    func select(_ command: TerminalCommand) {
        selectedCommand = command
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
