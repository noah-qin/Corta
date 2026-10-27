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

/// What a pane's search needs from the pane: the view the bar sits in,
/// the grid it sweeps, and the viewport it moves.
protocol PaneSearchHost: AnyObject {
    /// The pane's own view; the bar is its subview.
    var view: NSView { get }
    /// Where the cursor and matches are drawn, for keeping the bar clear of
    /// them; nil for a pane without one, which never moves the bar.
    var terminalView: TerminalView! { get }
    /// The top of the grid, below any window chrome over the pane.
    var topInset: CGFloat { get }
    /// Rows above the live bottom; a match scrolls it.
    var scrollOffset: Int { get set }
    /// The grid now, or nil without a session.
    func snapshot() -> Grid?
    /// The selected text, for ⌘E.
    func selectedText() -> String?
    /// For changes that produce no output: highlights, the viewport.
    func invalidateDisplay()
}

/// Scrollback search in one pane: the glass bar, its key routing, and the
/// matches the renderer highlights. Matching is the core's (`Search.find`,
/// over logical lines, so wrapped matches are whole).
///
/// Keys arrive two ways: the Find menu (⌘F, ⌘G, ⇧⌘G) through the responder
/// chain, which the pane forwards here (`performFindPanelAction(_:)`) — and
/// `TerminalView.onSearchKey` for Esc, which has no menu item and must never
/// reach the child while the bar is open.
final class PaneSearch: NSObject {
    weak var host: PaneSearchHost?

    /// The hosted `SearchBarView`, while the bar is open.
    var bar: NSView?
    let barModel = SearchBarModel()
    /// The bar sits top-right; it moves to the bottom-right while the cursor
    /// or the current match would sit under it. One of the pair is active.
    var topConstraint: NSLayoutConstraint?
    var bottomConstraint: NSLayoutConstraint?
    var field: NSTextField?
    /// In the coordinates of the sweep that found them: rows as they were
    /// when `matchesTotalPushed` lines had been pushed.
    private(set) var matches: [SelectionRange] = []
    /// `Scrollback.totalPushed` of the grid the matches were found in.
    private(set) var matchesTotalPushed = 0
    /// `matches` as the renderer draws them, built once per sweep. Built per
    /// frame, every frame allocated the whole list and stamped it with that
    /// frame's `totalPushed`, so output arriving between sweeps both rebuilt
    /// the overlay and drew each highlight that many rows off its text.
    private(set) var highlights: [TerminalSelection] = []
    var currentMatchIndex: Int?

    /// Absolute row (totalPushed + row), stable while output scrolls.
    var currentMatchAnchor: Int?

    var status: SweepOutcome.Status = .complete
    var matchesTruncated = false
    var task: Task<Void, Never>?
    /// Paired scroll position and scrollback anchor, restored when search closes.
    var previousScrollOffset: Int?
    var previousTotalPushed: Int?
    /// Reject results from superseded sweeps; retain output arriving during a sweep.
    var generation = 0
    var needsRefresh = false
    /// When the last sweep landed, and the wake that runs a refresh held
    /// back to `refreshPacing` after it. With the bar open over a stream of
    /// output, sweeps used to run back to back — a core busy for as long as
    /// the bar stayed open.
    private var lastSweepLanded: ContinuousClock.Instant?
    private var pacingWake: Task<Void, Never>?
    /// The least time from one output-driven sweep landing to the next one
    /// starting. A typed query is never held back.
    static let refreshPacing: Duration = .milliseconds(250)
    /// Optional test barrier for deterministic background-sweep races.
    var sweepGate: (@Sendable () -> Void)?
    var caseSensitive = false
    var regex = false
    var keyMonitor: Any?

    init(host: PaneSearchHost? = nil) {
        self.host = host
    }

    /// A sweep's matches plus whether the count can be trusted.
    struct SweepOutcome: Sendable {
        var matches: [SelectionRange]
        var status: Status

        enum Status: Sendable {
            /// The whole document was searched.
            case complete
            /// The sweep hit the match cap, a line too long to run a pattern
            /// against, or its time budget. The count is a floor.
            case incomplete
            /// The pattern does not compile.
            case invalidPattern
            /// The pattern's shape makes a backtracking engine take
            /// exponential time, so it was refused before it ran.
            case patternTooSlow
        }
    }

    /// Debounce before a sweep: a typing burst becomes one scan. The field
    /// reports every keystroke (`sendsSearchStringImmediately`) so the
    /// coalescing, and the cancelling, happens here.
    private static let debounceMilliseconds = 150

    // MARK: - Key routing

    /// The bar's keys while the terminal view is first responder; returns
    /// whether the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 /* kVK_Escape */, bar != nil {
            close()
            return true
        }
        // Find comes from the bindings, so a rebind or unbind really removes ⌘F.
        // ⌘G / ⇧⌘G are fixed menu items with no `bind.` key.
        let bindings = ConfigurationStore.shared.configuration.keybindings
        if bindings[.find]?.matches(event) == true {
            show()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        guard flags.contains(.command), bar != nil,
            event.charactersIgnoringModifiers?.lowercased() == "g"
        else { return false }
        if flags.contains(.shift) { showPreviousMatch() } else { showNextMatch() }
        return true
    }

    /// Esc closes the bar from anywhere in this pane's window. The local
    /// monitor fires app-wide, so the window check keeps other windows' Esc
    /// alone, and `isResponderActive` picks the right pane when a
    /// split has two open bars. Returns the event when it isn't ours.
    func handleGlobalEscape(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53 /* kVK_Escape */, let host,
            event.window === host.view.window, isResponderActive
        else {
            return event
        }
        close()
        return nil
    }

    static func keyMonitorHandler(for search: PaneSearch) -> (NSEvent) -> NSEvent? {
        { [weak search] event in
            guard let search else { return event }
            return search.handleGlobalEscape(event)
        }
    }

    /// Whether the first responder belongs to this pane's search bar: either
    /// the field editor, whose delegate is our `field`, or a bar
    /// control focused by Full Keyboard Access, found by ancestry.
    private var isResponderActive: Bool {
        guard let responder = host?.view.window?.firstResponder else { return false }
        if let text = responder as? NSText, text.delegate === field { return true }
        if let responderView = responder as? NSView, let searchBar = bar {
            return responderView.isDescendant(of: searchBar)
        }
        return false
    }

    /// Menu tags: 1 show, 2 next, 3 previous, 7 use selection. Replace
    /// actions are ignored.
    @objc func performFindPanelAction(_ sender: Any?) {
        switch (sender as? NSMenuItem)?.tag {
        case 1: show()
        case 2: showNextMatch()
        case 3: showPreviousMatch()
        case 7: useSelectionForFind()
        default: break
        }
    }

    // MARK: - The bar

    /// The bar's text field, bare: the glass pill is the container, and a
    /// bezel would draw a second rounded rect, focus ring and magnifying
    /// glass inside it.
    private func makeField() -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = L10n.text("search.placeholder")
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        return field
    }

    /// The bar's toggles, empty count and buttons, for a newly shown bar.
    private func resetBarModel() {
        barModel.caseSensitive = caseSensitive
        barModel.regex = regex
        barModel.countText = ""
        barModel.onToggleCase = { [weak self] in self?.toggleSearchCase() }
        barModel.onToggleRegex = { [weak self] in self?.toggleSearchRegex() }
        barModel.onPrevious = { [weak self] in self?.showPreviousMatch() }
        barModel.onNext = { [weak self] in self?.showNextMatch() }
        barModel.onClose = { [weak self] in self?.close() }
    }

    /// Shows the bar or refocuses its field, remembering the scroll position
    /// for close.
    func show() {
        guard let host else { return }
        if let searchField = field {
            host.view.window?.makeFirstResponder(searchField)
            return
        }
        let view = host.view
        // `totalPushed` first: the snapshot can wait on the reader's lock, and
        // reading `scrollOffset` second keeps the pair no staler than it.
        previousTotalPushed = host.snapshot()?.scrollback.totalPushed
        previousScrollOffset = host.scrollOffset
        // Seeded from the global default, then local to this pane.
        caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        regex = ConfigurationStore.shared.configuration.searchRegex

        let field = makeField()
        resetBarModel()

        let container = SearchBarView.hostingView(model: barModel, field: field)
        view.addSubview(container)
        // `topInset`, not `windowChrome`: only a top pane sits under the chrome.
        let top = container.topAnchor.constraint(
            equalTo: view.topAnchor, constant: host.topInset + 2)
        let bottom = container.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -Self.bottomMargin)
        // A narrow pane squeezes the field rather than pushing the pill off
        // the pane's leading edge; below its minimum, the edge gives.
        let leading = container.leadingAnchor.constraint(
            greaterThanOrEqualTo: view.leadingAnchor, constant: 14)
        leading.priority = .init(999)
        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            leading, top,
        ])
        topConstraint = top
        bottomConstraint = bottom
        view.layoutSubtreeIfNeeded()

        // Ease in, or appear at once under Reduce Motion.
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SystemAccessibility.duration(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.animator().alphaValue = 1
        }

        self.bar = container
        self.field = field
        placeClearOfContent()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown,
            handler: Self.keyMonitorHandler(for: self))
        view.window?.makeFirstResponder(field)
    }

    /// Dismisses the bar and restores the viewport.
    func close() {
        bar?.removeFromSuperview()
        topConstraint = nil
        bottomConstraint = nil
        bar = nil
        field = nil
        if let searchKeyMonitor = keyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
            keyMonitor = nil
        }
        setMatches([], totalPushed: 0)
        matchesTruncated = false
        currentMatchIndex = nil
        // Cancel, so `Search.find` stops burning CPU; the generation bump drops a
        // result already past its cancellation checks.
        task?.cancel()
        task = nil
        pacingWake?.cancel()
        pacingWake = nil
        needsRefresh = false
        generation &+= 1
        if let beforeSearch = previousScrollOffset, let host {
            if beforeSearch == 0 {
                // Zero means "follow the live bottom", so it stays zero.
                host.scrollOffset = 0
            } else {
                // Shift by scrollback growth since capture, like a selection's
                // `baseScrollbackTotal`, so it lands on the same text.
                let scrollback = host.snapshot()?.scrollback
                let reanchored = ScrollbackCoordinates.reanchoredOffset(
                    beforeSearch, from: previousTotalPushed ?? 0, to: scrollback?.totalPushed ?? 0)
                host.scrollOffset = min(scrollback?.count ?? beforeSearch, reanchored)
            }
        }
        previousScrollOffset = nil
        previousTotalPushed = nil
        host?.invalidateDisplay()
        host?.view.window?.makeFirstResponder(host?.terminalView)
    }

}

// MARK: - Matching

extension PaneSearch {

    /// Re-runs the query off the main thread, recomputing rather than patching.
    /// `scrollsToMatch` jumps a fresh query to the newest match; a refresh
    /// keeps the user's place.
    ///
    /// A detached task holds the debounce and the scan, both cancellable, so
    /// fast typing pays only for the newest query; the generation counter
    /// discards a result that slipped past cancellation.
    func updateResults(scrollsToMatch: Bool) {
        guard bar != nil, let searchField = field, let grid = host?.snapshot() else { return }
        generation &+= 1
        let generation = self.generation
        task?.cancel()
        task = nil
        let query = searchField.stringValue
        // Clear synchronously, so highlights vanish with the last character.
        guard !query.isEmpty else {
            setMatches([], totalPushed: 0)
            matchesTruncated = false
            currentMatchIndex = nil
            // Moot without a query; left set, output would trigger empty sweeps.
            needsRefresh = false
            updateCountLabel()
            host?.invalidateDisplay()
            return
        }
        let caseSensitive = self.caseSensitive
        let regex = self.regex
        // Copy-on-write: a few retains, not a copy.
        let totalPushed = grid.scrollback.totalPushed
        // This sweep already reads the current grid.
        needsRefresh = false
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // A cancelled sleep throws, so a superseded query never scans.
            do {
                try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            } catch { return }
            let outcome = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex)
            await MainActor.run {
                self?.applyResults(
                    outcome, generation: generation, scrollsToMatch: scrollsToMatch,
                    totalPushed: totalPushed)
            }
        }
    }

    /// Output-triggered refresh from the output-batch stage. Never scrolls, so the
    /// viewport stays on the match the user is reading.
    ///
    /// One sweep at most in flight. Output arriving meanwhile sets
    /// `needsRefresh`, which `applyResults` honours; otherwise
    /// the last output could leave results stale once the grid goes quiet.
    func scheduleBackgroundRefresh() {
        guard bar != nil, let searchField = field, let grid = host?.snapshot() else { return }
        guard task == nil else {
            needsRefresh = true
            return
        }
        if let landed = lastSweepLanded {
            let elapsed = landed.duration(to: .now)
            if elapsed < Self.refreshPacing {
                needsRefresh = true
                guard pacingWake == nil else { return }
                pacingWake = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.refreshPacing - elapsed)
                    guard let self, !Task.isCancelled else { return }
                    self.pacingWake = nil
                    guard self.needsRefresh else { return }
                    self.needsRefresh = false
                    self.scheduleBackgroundRefresh()
                }
                return
            }
        }
        generation &+= 1
        let generation = self.generation
        let query = searchField.stringValue
        let totalPushed = grid.scrollback.totalPushed
        let caseSensitive = self.caseSensitive
        let regex = self.regex
        let gate = sweepGate
        task = Task.detached(priority: .utility) { [weak self] in
            gate?()
            let outcome = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex)
            await MainActor.run {
                self?.applyResults(
                    outcome, generation: generation, scrollsToMatch: false,
                    totalPushed: totalPushed)
            }
        }
    }

    /// Applies a sweep only if it is still current; a newer query or a
    /// closed bar may have made the grid or `field` stale.
    func applyResults(
        _ outcome: SweepOutcome, generation: Int, scrollsToMatch: Bool, totalPushed: Int
    ) {
        guard generation == self.generation, bar != nil else { return }
        status = outcome.status
        // The generation matched, so `task` is this finished task.
        task = nil
        lastSweepLanded = .now
        setMatches(outcome.matches, totalPushed: totalPushed)
        matchesTruncated = matches.count >= Search.defaultMatchLimit
        if matches.isEmpty {
            currentMatchIndex = nil
            currentMatchAnchor = nil
        } else if scrollsToMatch || currentMatchAnchor == nil {
            currentMatchIndex = matches.count - 1
            noteCurrentMatchAnchor(totalPushed: totalPushed)
            scrollToCurrentMatch()
        } else {
            // Keep the current match's text, not its index: output shifts indices,
            // and following the number jumped to different text on every print.
            currentMatchIndex = Self.index(
                closestTo: currentMatchAnchor, in: matches, totalPushed: totalPushed)
            noteCurrentMatchAnchor(totalPushed: totalPushed)
        }
        updateCountLabel()
        placeClearOfContent()
        host?.invalidateDisplay()
        // Catch up on output that arrived during this sweep.
        if needsRefresh {
            needsRefresh = false
            scheduleBackgroundRefresh()
        }
    }

    private func noteCurrentMatchAnchor(totalPushed: Int) {
        guard let index = currentMatchIndex, matches.indices.contains(index) else {
            currentMatchAnchor = nil
            return
        }
        currentMatchAnchor = ScrollbackCoordinates.absoluteRow(
            matches[index].start.row, totalPushed: totalPushed)
    }

    func showNextMatch() {
        stepCurrentMatch(by: 1)
    }

    func showPreviousMatch() {
        stepCurrentMatch(by: -1)
    }

    /// ⌘E: the selection's first line becomes the query.
    func useSelectionForFind() {
        guard let text = host?.selectedText() else { return }
        guard let firstLine = text.split(separator: "\n").first.map(String.init),
            !firstLine.isEmpty
        else { return }
        show()
        field?.stringValue = firstLine
        updateResults(scrollsToMatch: true)
    }

    private func stepCurrentMatch(by delta: Int) {
        guard !matches.isEmpty else { return }
        let current = currentMatchIndex ?? matches.count - 1
        currentMatchIndex =
            (current + delta + matches.count) % matches.count
        noteCurrentMatchAnchor(totalPushed: matchesTotalPushed)
        scrollToCurrentMatch()
        updateCountLabel()
        placeClearOfContent()
        host?.invalidateDisplay()
    }

    /// Centres the current match: row `r` shows at `r + scrollOffset`, so the
    /// offset is `rows/2 - r`. Live-screen matches don't scroll.
    private func scrollToCurrentMatch() {
        guard let index = currentMatchIndex, matches.indices.contains(index),
            let host, let grid = host.snapshot()
        else { return }
        let row = liveRow(matches[index].start.row, in: grid)
        host.scrollOffset =
            row >= 0
            ? 0
            : min(grid.scrollback.count, max(0, grid.rows / 2 - row))
    }

    private func setMatches(_ found: [SelectionRange], totalPushed: Int) {
        matches = found
        matchesTotalPushed = totalPushed
        highlights = found.map { TerminalSelection($0, baseScrollbackTotal: totalPushed) }
    }

    /// A match row where it is now, after the output since its sweep.
    func liveRow(_ row: Int, in grid: Grid) -> Int {
        ScrollbackCoordinates.reanchoredRow(
            row, from: matchesTotalPushed, to: grid.scrollback.totalPushed)
    }

    private func updateCountLabel() {
        guard bar != nil else { return }
        if status == .invalidPattern {
            barModel.countText = L10n.text("search.invalidPattern")
        } else if status == .patternTooSlow {
            barModel.countText = L10n.text("search.patternTooSlow")
        } else if matches.isEmpty {
            barModel.countText = field?.stringValue.isEmpty == false ? L10n.text("search.noResults") : ""
        } else if let current = currentMatchIndex {
            // "+" when the sweep stopped early (the match cap, an over-long line, or
            // the time budget): there may be uncounted matches.
            barModel.countText =
                "\(current + 1)/\(matches.count)"
                + (status == .incomplete ? "+" : "")
        }
    }

    /// Flips this pane's case sensitivity and saves it as the default for
    /// bars opened later; other open bars keep theirs.
    func toggleSearchCase() {
        caseSensitive.toggle()
        if !ConfigurationStore.shared.update({ $0.searchCaseSensitive = self.caseSensitive }) {
            // A failed write rolls the config back; match it.
            caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        }
        barModel.caseSensitive = caseSensitive
        // The list changes; re-find the place rather than keep it.
        currentMatchAnchor = nil
        updateResults(scrollsToMatch: true)
    }

    /// As `toggleSearchCase`, for regex mode.
    func toggleSearchRegex() {
        regex.toggle()
        if !ConfigurationStore.shared.update({ $0.searchRegex = self.regex }) {
            // See `toggleSearchCase`.
            regex = ConfigurationStore.shared.configuration.searchRegex
        }
        barModel.regex = regex
        currentMatchAnchor = nil
        updateResults(scrollsToMatch: true)
    }
}
