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

import Cocoa
import CortaTerminal

/// Scrollback search: the glass bar, its key routing, and the matches the
/// renderer highlights. Matching is the core's (`Search.find`, over logical
/// lines, so wrapped matches are whole).
///
/// Keys arrive two ways: the Find menu (⌘F, ⌘G, ⇧⌘G) through the responder
/// chain, and `TerminalView.onSearchKey` for Esc, which has no menu item
/// and must never reach the child while the bar is open.
extension ViewController {
    /// Debounce before a sweep: a typing burst becomes one scan. The field
    /// reports every keystroke (`sendsSearchStringImmediately`) so the
    /// coalescing, and the cancelling, happens here.
    private static let searchDebounceMilliseconds = 150

    // MARK: - Key routing

    /// The bar's keys while the terminal view is first responder; returns
    /// whether the event was consumed.
    func handleSearchKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 /* kVK_Escape */, search.bar != nil {
            closeSearchBar()
            return true
        }
        // Find comes from the bindings, so a rebind or unbind really removes ⌘F.
        // ⌘G / ⇧⌘G are storyboard items with no `bind.` key.
        let bindings = ConfigurationStore.shared.configuration.keybindings
        if bindings[.find]?.matches(event) == true {
            showSearchBar()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        guard flags.contains(.command), search.bar != nil,
            event.charactersIgnoringModifiers?.lowercased() == "g"
        else { return false }
        if flags.contains(.shift) { showPreviousMatch() } else { showNextMatch() }
        return true
    }

    /// Esc closes the bar from anywhere in this pane's window. The local
    /// monitor fires app-wide, so the window check keeps other windows' Esc
    /// alone, and `isSearchBarResponderActive` picks the right pane when a
    /// split has two open bars. Returns the event when it isn't ours.
    func handleGlobalSearchEscape(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53 /* kVK_Escape */, event.window === view.window,
            isSearchBarResponderActive
        else {
            return event
        }
        closeSearchBar()
        return nil
    }

    /// Whether the first responder belongs to this pane's search bar: either
    /// the field editor, whose delegate is our `search.field`, or a bar
    /// control focused by Full Keyboard Access, found by ancestry.
    private var isSearchBarResponderActive: Bool {
        guard let responder = view.window?.firstResponder else { return false }
        if let text = responder as? NSText, text.delegate === search.field { return true }
        if let responderView = responder as? NSView, let searchBar = search.bar {
            return responderView.isDescendant(of: searchBar)
        }
        return false
    }

    /// Storyboard tags: 1 show, 2 next, 3 previous, 7 use selection. Replace
    /// actions are ignored.
    @objc func performFindPanelAction(_ sender: Any?) {
        switch (sender as? NSMenuItem)?.tag {
        case 1: showSearchBar()
        case 2: showNextMatch()
        case 3: showPreviousMatch()
        case 7: useSelectionForFind()
        default: break
        }
    }

    // MARK: - The bar

    /// Shows the bar or refocuses its field, remembering the scroll position
    /// for close.
    func showSearchBar() {
        if let searchField = search.field {
            view.window?.makeFirstResponder(searchField)
            return
        }
        // `totalPushed` first: the snapshot can wait on the reader's lock, and
        // reading `scrollOffset` second keeps the pair no staler than it.
        search.previousTotalPushed = session?.snapshot().scrollback.totalPushed
        search.previousScrollOffset = scrollOffset
        // Seeded from the global default, then local to this pane.
        search.caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        search.regex = ConfigurationStore.shared.configuration.searchRegex

        // One weight and size so the symbols read as a set.
        let symbols = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(scale: .small))

        let glass = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = symbols
        glass.contentTintColor = SystemAccessibility.secondaryLabelColor

        let field = NSSearchField()
        field.placeholderString = L10n.text("search.placeholder")
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        // The glass pill is the container; a bezel would draw a second rounded
        // rect, focus ring and magnifying glass inside it.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true

        // Monospaced digits, so the buttons don't twitch as the count changes.
        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = SystemAccessibility.secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        func button(_ symbolName: String, _ description: String, _ action: Selector) -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbolName, accessibilityDescription: description)!,
                target: self, action: action)
            button.isBordered = false
            button.symbolConfiguration = symbols
            button.contentTintColor = SystemAccessibility.secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }

        // On/off shows in the tint and the accessibility value, never tint alone.
        let caseButton = button(
            "textformat", L10n.text("search.caseSensitive"), #selector(toggleSearchCase(_:)))
        updateCaseButton(caseButton)
        let regexButton = button(
            "asterisk", L10n.text("search.regex"), #selector(toggleSearchRegex(_:)))
        updateRegexButton(regexButton)

        let stack = NSStackView(views: [
            glass, field, countLabel, separator, caseButton, regexButton,
            button("chevron.up", "Previous Match", #selector(searchBarPrevious(_:))),
            button("chevron.down", "Next Match", #selector(searchBarNext(_:))),
            button("xmark", "Close Find", #selector(searchBarClose(_:))),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(8, after: glass)
        stack.setCustomSpacing(10, after: countLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(2, after: stack.views[4])
        stack.setCustomSpacing(8, after: stack.views[5])
        stack.setCustomSpacing(2, after: stack.views[6])
        stack.setCustomSpacing(6, after: stack.views[7])
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The container merges neighbouring glass into one render batch.
        let container = NSGlassEffectContainerView()
        let bar = NSGlassEffectView()
        bar.style = .regular
        // A theme tint keeps the pill readable over any output. Reduce
        // Transparency means nothing shows through, so the tint goes opaque.
        bar.tintColor =
            SystemAccessibility.reduceTransparency
            ? .windowBackgroundColor
            : .windowBackgroundColor.withAlphaComponent(0.55)
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        bar.contentView = content
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The container merges descendants of `contentView`, so the glass goes in
        // a wrapper; placed in `contentView` directly it merged nothing.
        let wrapper = NSView()
        wrapper.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            bar.topAnchor.constraint(equalTo: wrapper.topAnchor),
            bar.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        container.contentView = wrapper
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            // `topInset`, not `windowChrome`: only a top pane sits under the chrome.
            container.topAnchor.constraint(
                equalTo: view.topAnchor, constant: topInset + 2),
        ])
        // A pill: half the laid-out height.
        view.layoutSubtreeIfNeeded()
        bar.cornerRadius = bar.bounds.height / 2

        // An opaque or high-contrast pill needs a drawn edge.
        if SystemAccessibility.increaseContrast || SystemAccessibility.reduceTransparency {
            let border = SystemAccessibility.panelBorder
            wrapper.wantsLayer = true
            wrapper.layer?.cornerRadius = bar.cornerRadius
            wrapper.layer?.borderColor = border.color.cgColor
            wrapper.layer?.borderWidth = border.width
        }

        // Ease in, or appear at once under Reduce Motion.
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SystemAccessibility.duration(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.animator().alphaValue = 1
        }

        search.bar = bar
        search.container = container
        search.field = field
        search.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalSearchEscape(event) ?? event
        }
        view.window?.makeFirstResponder(field)
    }

    /// Dismisses the bar and restores the viewport.
    func closeSearchBar() {
        search.container?.removeFromSuperview()
        search.container = nil
        search.bar = nil
        search.field = nil
        if let searchKeyMonitor = search.keyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
            self.search.keyMonitor = nil
        }
        search.matches = []
        search.matchesTruncated = false
        search.currentMatchIndex = nil
        // Cancel, so `Search.find` stops burning CPU; the generation bump drops a
        // result already past its cancellation checks.
        search.task?.cancel()
        search.task = nil
        search.needsRefresh = false
        search.generation &+= 1
        if let beforeSearch = search.previousScrollOffset {
            if beforeSearch == 0 {
                // Zero means "follow the live bottom", so it stays zero.
                scrollOffset = 0
            } else {
                // Shift by scrollback growth since capture, like a selection's
                // `baseScrollbackTotal`, so it lands on the same text.
                let scrollback = session?.snapshot().scrollback
                let reanchored = ScrollbackCoordinates.reanchoredOffset(
                    beforeSearch, from: search.previousTotalPushed ?? 0, to: scrollback?.totalPushed ?? 0)
                scrollOffset = min(scrollback?.count ?? beforeSearch, reanchored)
            }
            search.previousScrollOffset = nil
            search.previousTotalPushed = nil
        }
        invalidateDisplay()
        view.window?.makeFirstResponder(terminalView)
    }

    // MARK: - Matching

    /// Re-runs the query off the main thread, recomputing rather than patching.
    /// `scrollsToMatch` jumps a fresh query to the newest match; a refresh
    /// keeps the user's place.
    ///
    /// A detached task holds the debounce and the scan, both cancellable, so
    /// fast typing pays only for the newest query; the generation counter
    /// discards a result that slipped past cancellation.
    func updateSearchResults(scrollsToMatch: Bool) {
        guard search.bar != nil, let searchField = search.field, session != nil else { return }
        search.generation &+= 1
        let generation = search.generation
        search.task?.cancel()
        search.task = nil
        let query = searchField.stringValue
        // Clear synchronously, so highlights vanish with the last character.
        guard !query.isEmpty else {
            search.matches = []
            search.matchesTruncated = false
            search.currentMatchIndex = nil
            // Moot without a query; left set, output would trigger empty sweeps.
            search.needsRefresh = false
            updateSearchCountLabel()
            invalidateDisplay()
            return
        }
        let caseSensitive = search.caseSensitive
        let regex = search.regex
        // Copy-on-write: a few retains, not a copy.
        let grid = session.snapshot()
        let totalPushed = grid.scrollback.totalPushed
        // This sweep already reads the current grid.
        search.needsRefresh = false
        search.task = Task.detached(priority: .userInitiated) { [weak self] in
            // A cancelled sleep throws, so a superseded query never scans.
            do {
                try await Task.sleep(for: .milliseconds(Self.searchDebounceMilliseconds))
            } catch { return }
            let outcome = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex)
            await MainActor.run {
                self?.applySearchResults(
                    outcome, generation: generation, scrollsToMatch: scrollsToMatch,
                    totalPushed: totalPushed)
            }
        }
    }

    /// Output-triggered refresh from `prepareFrame`. Never scrolls, so the
    /// viewport stays on the match the user is reading.
    ///
    /// One sweep at most in flight. Output arriving meanwhile sets
    /// `search.needsRefresh`, which `applySearchResults` honours; otherwise
    /// the last output could leave results stale once the grid goes quiet.
    func scheduleBackgroundSearchRefresh() {
        guard search.bar != nil, let searchField = search.field, let session else { return }
        guard search.task == nil else {
            search.needsRefresh = true
            return
        }
        search.generation &+= 1
        let generation = search.generation
        let query = searchField.stringValue
        let grid = session.snapshot()
        let totalPushed = grid.scrollback.totalPushed
        let caseSensitive = search.caseSensitive
        let regex = search.regex
        let gate = search.sweepGate
        search.task = Task.detached(priority: .utility) { [weak self] in
            gate?()
            let outcome = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex)
            await MainActor.run {
                self?.applySearchResults(
                    outcome, generation: generation, scrollsToMatch: false,
                    totalPushed: totalPushed)
            }
        }
    }

    /// One sweep in either mode, pure and `nonisolated` so both detached
    /// tasks share it.
    nonisolated static func sweep(
        _ query: String, in grid: Grid, caseSensitive: Bool, regex: Bool
    ) -> SweepOutcome {
        guard regex else {
            let matches = Search.find(
                query, in: grid, caseSensitive: caseSensitive,
                maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled })
            return SweepOutcome(
                matches: matches,
                status: matches.count >= Search.defaultMatchLimit ? .incomplete : .complete)
        }
        // An invalid or catastrophic-backtracking pattern is its own state, not
        // "no results": the search never ran.
        guard Search.isValidRegex(query, caseSensitive: caseSensitive) else {
            return SweepOutcome(matches: [], status: .invalidPattern)
        }
        guard !Search.isCatastrophic(query) else {
            return SweepOutcome(matches: [], status: .patternTooSlow)
        }
        let result = Search.findRegex(
            query, in: grid, caseSensitive: caseSensitive,
            maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled })
        return SweepOutcome(
            matches: result.matches,
            status: result.isIncomplete ? .incomplete : .complete)
    }

    /// A sweep's matches plus whether the count can be trusted.
    typealias SweepOutcome = PaneSearchState.SweepOutcome

    /// Applies a sweep only if it is still current; a newer query or a
    /// closed bar may have made `session` or `search.field` stale.
    private func applySearchResults(
        _ outcome: SweepOutcome, generation: Int, scrollsToMatch: Bool, totalPushed: Int
    ) {
        let matches = outcome.matches
        search.status = outcome.status
        guard generation == search.generation, search.bar != nil else { return }
        // The generation matched, so `search.task` is this finished task.
        search.task = nil
        search.matches = matches
        search.matchesTruncated = matches.count >= Search.defaultMatchLimit
        if search.matches.isEmpty {
            search.currentMatchIndex = nil
            search.currentMatchAnchor = nil
        } else if scrollsToMatch || search.currentMatchAnchor == nil {
            search.currentMatchIndex = search.matches.count - 1
            noteCurrentMatchAnchor(totalPushed: totalPushed)
            scrollToCurrentMatch()
        } else {
            // Keep the current match's text, not its index: output shifts indices,
            // and following the number jumped to different text on every print.
            search.currentMatchIndex = Self.index(
                closestTo: search.currentMatchAnchor, in: search.matches, totalPushed: totalPushed)
            noteCurrentMatchAnchor(totalPushed: totalPushed)
        }
        updateSearchCountLabel()
        invalidateDisplay()
        // Catch up on output that arrived during this sweep.
        if search.needsRefresh {
            search.needsRefresh = false
            scheduleBackgroundSearchRefresh()
        }
    }

    /// The match nearest a remembered absolute row: the exact line may be
    /// evicted or rewritten, and a neighbour beats losing the place.
    static func index(
        closestTo anchor: Int?, in matches: [SelectionRange], totalPushed: Int
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let anchor else { return matches.count - 1 }
        var best = 0
        var bestDistance = Int.max
        for (index, match) in matches.enumerated() {
            let distance = abs(
                ScrollbackCoordinates.absoluteRow(match.start.row, totalPushed: totalPushed) - anchor)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func noteCurrentMatchAnchor(totalPushed: Int) {
        guard let index = search.currentMatchIndex, search.matches.indices.contains(index) else {
            search.currentMatchAnchor = nil
            return
        }
        search.currentMatchAnchor = ScrollbackCoordinates.absoluteRow(
            search.matches[index].start.row, totalPushed: totalPushed)
    }

    func showNextMatch() {
        stepCurrentMatch(by: 1)
    }

    func showPreviousMatch() {
        stepCurrentMatch(by: -1)
    }

    /// ⌘E: the selection's first line becomes the query.
    func useSelectionForFind() {
        guard let selection, session != nil else { return }
        let grid = session.snapshot()
        let text = Selection.text(of: selectionRange(for: selection, in: grid), in: grid)
        guard let firstLine = text.split(separator: "\n").first.map(String.init),
            !firstLine.isEmpty
        else { return }
        showSearchBar()
        search.field?.stringValue = firstLine
        updateSearchResults(scrollsToMatch: true)
    }

    private func stepCurrentMatch(by delta: Int) {
        guard !search.matches.isEmpty, session != nil else { return }
        let current = search.currentMatchIndex ?? search.matches.count - 1
        search.currentMatchIndex =
            (current + delta + search.matches.count) % search.matches.count
        noteCurrentMatchAnchor(totalPushed: session.snapshot().scrollback.totalPushed)
        scrollToCurrentMatch()
        updateSearchCountLabel()
        invalidateDisplay()
    }

    /// Centres the current match: row `r` shows at `r + scrollOffset`, so the
    /// offset is `rows/2 - r`. Live-screen matches don't scroll.
    private func scrollToCurrentMatch() {
        guard let index = search.currentMatchIndex, search.matches.indices.contains(index),
            session != nil
        else { return }
        let grid = session.snapshot()
        let row = search.matches[index].start.row
        scrollOffset =
            row >= 0
            ? 0
            : min(grid.scrollback.count, max(0, grid.rows / 2 - row))
    }

    private func updateSearchCountLabel() {
        // Found by type so the bar's construction stays in one place.
        let label = search.bar?.contentView?.subviews
            .compactMap { $0 as? NSStackView }.first?
            .arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { !($0 is NSSearchField) }
        guard let label else { return }
        if search.status == .invalidPattern {
            label.stringValue = L10n.text("search.invalidPattern")
        } else if search.status == .patternTooSlow {
            label.stringValue = L10n.text("search.patternTooSlow")
        } else if search.matches.isEmpty {
            label.stringValue = search.field?.stringValue.isEmpty == false ? "No Results" : ""
        } else if let current = search.currentMatchIndex {
            // "+" when the sweep stopped early (the match cap, an over-long line, or
            // the time budget): there may be uncounted matches.
            label.stringValue =
                "\(current + 1)/\(search.matches.count)"
                + (search.status == .incomplete ? "+" : "")
        }
    }

    /// Flips this pane's case sensitivity and saves it as the default for
    /// bars opened later; other open bars keep theirs.
    @objc private func toggleSearchCase(_ sender: Any?) {
        search.caseSensitive.toggle()
        if !ConfigurationStore.shared.update({ $0.searchCaseSensitive = self.search.caseSensitive }) {
            // A failed write rolls the config back; match it.
            search.caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        }
        if let button = sender as? NSButton { updateCaseButton(button) }
        // The list changes; re-find the place rather than keep it.
        search.currentMatchAnchor = nil
        updateSearchResults(scrollsToMatch: true)
    }

    /// As `toggleSearchCase`, for regex mode.
    @objc private func toggleSearchRegex(_ sender: Any?) {
        search.regex.toggle()
        if !ConfigurationStore.shared.update({ $0.searchRegex = self.search.regex }) {
            // See `toggleSearchCase`.
            search.regex = ConfigurationStore.shared.configuration.searchRegex
        }
        if let button = sender as? NSButton { updateRegexButton(button) }
        search.currentMatchAnchor = nil
        updateSearchResults(scrollsToMatch: true)
    }

    private func updateRegexButton(_ button: NSButton) {
        let on = search.regex
        button.contentTintColor = on ? .controlAccentColor : SystemAccessibility.secondaryLabelColor
        button.setAccessibilityValue(on ? 1 : 0)
        button.toolTip = L10n.text("search.regex")
    }

    /// Tint for a glance; the accessibility value states it outright.
    private func updateCaseButton(_ button: NSButton) {
        let on = search.caseSensitive
        button.contentTintColor = on ? .controlAccentColor : SystemAccessibility.secondaryLabelColor
        button.setAccessibilityValue(on ? 1 : 0)
        button.toolTip = L10n.text("search.caseSensitive")
    }

    @objc private func searchBarNext(_ sender: Any?) {
        showNextMatch()
    }

    @objc private func searchBarPrevious(_ sender: Any?) {
        showPreviousMatch()
    }

    @objc private func searchBarClose(_ sender: Any?) {
        closeSearchBar()
    }
}

extension ViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === search.field else { return }
        updateSearchResults(scrollsToMatch: true)
    }

    /// Return is next match; Esc (sent as `cancelOperation:`) closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        guard control === search.field else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            showNextMatch()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSearchBar()
            return true
        }
        return false
    }
}
