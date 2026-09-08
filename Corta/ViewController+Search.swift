import Cocoa
import CortaTerminal

/// Scrollback search (M4.4): the glass bar, its key routing, and the match
/// model the renderer highlights.
///
/// Matching lives in the core (`Search.find`) over logical lines, so a match
/// spanning a soft wrap is found and highlighted whole. Everything here is
/// shell: a query string in, `[SelectionRange]` out, plus the scroll offset
/// that brings the current match on screen.
///
/// Key routing has two fronts. The Find menu's items (⌘F, ⌘G, ⇧⌘G) target
/// First Responder with `performFindPanelAction:` and land here from
/// anywhere in this window's responder chain. `TerminalView.keyDown` also
/// offers keys to `onSearchKey` first: the menu claims the ⌘ equivalents,
/// but Esc has no menu item — and while the bar is open a raw ESC byte must
/// never reach the child.
extension ViewController {
    /// Keystroke debounce before a query starts its sweep (P04): long
    /// enough that a typing burst becomes one scan, short enough that a
    /// deliberate pause reads as instant. Compare `NSSearchField`'s own
    /// debounce, which `sendsSearchStringImmediately` disables — the field
    /// reports every keystroke and the coalescing lives here instead, where
    /// it also cancels the superseded sweep.
    private static let searchDebounceMilliseconds = 150

    // MARK: - Key routing

    /// `TerminalView.onSearchKey`: the bar's keys when the terminal view —
    /// not the search field — is first responder. Returns whether the event
    /// was consumed; `false` continues the normal key routing.
    func handleSearchKey(_ event: NSEvent) -> Bool {
        // Esc closes the bar rather than sending a raw ESC to the child.
        if event.keyCode == 53 /* kVK_Escape */, searchBar != nil {
            closeSearchBar()
            return true
        }
        // Find comes from the binding table, not from a literal ⌘F: with the
        // literal here, `bind.find = cmd+e` left ⌘F opening the bar too and
        // `bind.find =` did not close that door at all (U08). Find Next and
        // Find Previous are the storyboard's own items and carry no `bind.`
        // key, so ⌘G / ⇧⌘G stay written in — there is no binding for them to
        // disagree with.
        let bindings = ConfigurationStore.shared.configuration.keybindings
        if bindings[.find]?.matches(event) == true {
            showSearchBar()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        guard flags.contains(.command), searchBar != nil,
            event.charactersIgnoringModifiers?.lowercased() == "g"
        else { return false }
        if flags.contains(.shift) { showPreviousMatch() } else { showNextMatch() }
        return true
    }

    /// The Find menu's items land here, tagged in the storyboard: 1 show,
    /// 2 next, 3 previous, 7 use-selection-for-find. Find and Replace and
    /// friends are ignored — a terminal has nothing to replace.
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

    /// Shows the bar, or refocuses its field if it is already open. The
    /// scroll position is remembered so closing the bar puts the viewport
    /// back where the user left it.
    func showSearchBar() {
        if let searchField {
            view.window?.makeFirstResponder(searchField)
            return
        }
        scrollOffsetBeforeSearch = scrollOffset

        // Symbols, not text, and all at one weight and point size so the
        // three of them read as a set rather than as three separate
        // controls. `.small` scale keeps them subordinate to the query.
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
        // The glass pill *is* the container. Left bezelled, the field drew a
        // second rounded rect (and its own focus ring) inside the first —
        // and its own magnifying glass and cancel button, which is why the
        // search-button cell is emptied here in favour of the one above.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true

        // Monospaced digits: without them "9/10" is narrower than "8/12" and
        // the buttons to its right twitch sideways as the user types.
        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = SystemAccessibility.secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        // A hairline, so the query and the controls that act on it are
        // visibly two groups inside one pill.
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
            // Square, so the two chevrons and the close mark sit on an even
            // rhythm instead of each hugging its own glyph's width.
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }

        // U12 — case sensitivity, as a toggle rather than a hidden default.
        // `textformat` is the symbol macOS itself uses for "how the text is
        // matched"; on/off is carried by the tint *and* by the accessibility
        // value, never by the tint alone.
        let caseButton = button(
            "textformat", L10n.text("search.caseSensitive"), #selector(toggleSearchCase(_:)))
        updateCaseButton(caseButton)
        // U16 — regular expressions, behind the same kind of toggle. `.*` is
        // what every editor's find bar puts on this button.
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
        // Tighter around the buttons than around the query: the buttons
        // already carry 22pt of their own box.
        stack.setCustomSpacing(8, after: glass)
        stack.setCustomSpacing(10, after: countLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(2, after: stack.views[4])
        stack.setCustomSpacing(8, after: stack.views[5])
        stack.setCustomSpacing(2, after: stack.views[6])
        stack.setCustomSpacing(6, after: stack.views[7])
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The search bar is where Liquid Glass belongs: a control floating
        // over content, refracting the terminal underneath it. The container
        // merges neighbouring glass surfaces and renders them as one batch
        // rather than a pass each, which is what it is for — the header calls
        // that out explicitly. One surface today; splits and any later
        // floating control join the same container.
        let container = NSGlassEffectContainerView()
        let bar = NSGlassEffectView()
        bar.style = .regular
        // The glass sits over arbitrary terminal output — a screen of
        // bright text on a light background, or the reverse — and an
        // untinted material let that output compete with the query being
        // typed. A theme-following tint keeps the pill readable in both
        // appearances. Reduce Transparency is not "less translucent", it is
        // "background content must not show through" — so there the tint
        // becomes fully opaque rather than merely lowered in alpha. The bar
        // keeps its shape and its position either way.
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
        // The container merges *descendants* of its `contentView` — the
        // header is explicit about that — so the glass goes inside a plain
        // wrapper, not into `contentView` itself. Assigning the glass there
        // directly left it with nothing to elevate and no merge to perform.
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
            // `topInset`, not `windowChrome`: in a split tree only a pane
            // touching the window's top edge sits under the chrome — the
            // bar hugs its own pane's top, not the window's (M5).
            container.topAnchor.constraint(
                equalTo: view.topAnchor, constant: topInset + 2),
        ])
        // A pill: half the bar's own height, resolved after layout rather
        // than guessed. A fixed 12 on a 36pt bar is a rounded rectangle, and
        // next to the window's own curvature it read as neither.
        view.layoutSubtreeIfNeeded()
        bar.cornerRadius = bar.bounds.height / 2

        // Under Increase Contrast — or once the material is opaque and has no
        // edge of its own left to read — the pill needs a drawn outline, or it
        // has no boundary against the terminal behind it.
        if SystemAccessibility.increaseContrast || SystemAccessibility.reduceTransparency {
            let border = SystemAccessibility.panelBorder
            wrapper.wantsLayer = true
            wrapper.layer?.cornerRadius = bar.cornerRadius
            wrapper.layer?.borderColor = border.color.cgColor
            wrapper.layer?.borderWidth = border.width
        }

        // Ease in. Appearing instantly at full size over a screen of text
        // reads as a glitch; the glass wants to look like it rose out of the
        // content — unless the user has asked for no motion, in which case the
        // duration collapses to zero and it simply is there.
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SystemAccessibility.duration(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.animator().alphaValue = 1
        }

        searchBar = bar
        searchBarContainer = container
        searchField = field
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc closes the bar from anywhere in the app — see the
            // property's comment for why a delegate method is not enough.
            guard event.keyCode == 53 /* kVK_Escape */ else { return event }
            self?.closeSearchBar()
            return nil
        }
        view.window?.makeFirstResponder(field)
    }

    /// Dismisses the bar, clears the highlights and puts the viewport back
    /// where it was before the search opened.
    func closeSearchBar() {
        // The container is what sits in the view hierarchy; removing only
        // the glass would leave it behind empty.
        searchBarContainer?.removeFromSuperview()
        searchBarContainer = nil
        searchBar = nil
        searchField = nil
        if let searchKeyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
            self.searchKeyMonitor = nil
        }
        searchMatches = []
        searchMatchesTruncated = false
        currentSearchMatchIndex = nil
        // A sweep still in flight is cancelled, not just discarded (P04):
        // `Search.find` polls `Task.isCancelled` between and within lines,
        // so a dead search stops burning CPU instead of finishing into the
        // void. The generation bump keeps a result that was already past
        // the cancellation check from being applied.
        searchTask?.cancel()
        searchTask = nil
        searchRefreshGeneration &+= 1
        if let beforeSearch = scrollOffsetBeforeSearch {
            scrollOffset = beforeSearch
            scrollOffsetBeforeSearch = nil
        }
        invalidateDisplay()
        view.window?.makeFirstResponder(terminalView)
    }

    // MARK: - Matching

    /// Re-runs the query, off the main thread (P04). Called on every
    /// keystroke and by `useSelectionForFind` — matches are recomputed,
    /// never incrementally patched (the core's logical-line pass over a
    /// full scrollback is one lazy sweep, `Search.swift`). `scrollsToMatch`
    /// distinguishes a fresh query, which jumps to the newest match — the
    /// one a shell user just watched print — from a background refresh,
    /// which keeps the user's place.
    ///
    /// The sweep runs on the cooperative pool, not the main actor (A03): a
    /// detached task holds the debounce sleep and the scan, and both are
    /// cancellable — a new keystroke cancels the old task (`Task.sleep`
    /// throws, `Search.find` polls `shouldStop` per line and per match), so
    /// fast typing only ever pays for the newest query. The generation
    /// counter is the second guard: a result that was already past the
    /// cancellation checks when the cancel landed is discarded on apply.
    func updateSearchResults(scrollsToMatch: Bool) {
        guard searchBar != nil, let searchField, session != nil else { return }
        searchRefreshGeneration &+= 1
        let generation = searchRefreshGeneration
        searchTask?.cancel()
        searchTask = nil
        let query = searchField.stringValue
        // An empty query needs no sweep — clear synchronously, so the
        // highlights vanish with the last character, not a debounce later.
        guard !query.isEmpty else {
            searchMatches = []
            searchMatchesTruncated = false
            currentSearchMatchIndex = nil
            updateSearchCountLabel()
            invalidateDisplay()
            return
        }
        let caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        let regex = ConfigurationStore.shared.configuration.searchRegex
        // Snapshotted on the main thread, but a Grid is copy-on-write — a
        // handful of retains, not a copy.
        let grid = session.snapshot()
        let totalPushed = grid.scrollback.totalPushed
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: a keystroke burst becomes one sweep, started once
            // the burst pauses. A cancelled sleep throws — a superseded
            // query never scans at all.
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

    /// PTY-output-triggered refresh, off the render path (M9) — see the
    /// call site in `ViewController.prepareFrame`. Unlike
    /// `updateSearchResults`, this never scrolls to the current match: an
    /// output-driven refresh must not yank the viewport out from under a
    /// user who is reading a match higher up, which is exactly the
    /// "keeps the user's place" behaviour `updateSearchResults`'s
    /// `scrollsToMatch: false` path already had — this preserves it, just
    /// off the main thread for the sweep itself.
    ///
    /// At most one sweep is ever in flight: an output batch that arrives
    /// while the previous recompute is still running is dropped, not
    /// queued — the in-flight snapshot is at most a frame old, and the
    /// next output frame starts a fresh sweep as soon as this one lands.
    /// During an output flood that keeps refresh at the sweep rate, not
    /// the frame rate.
    func scheduleBackgroundSearchRefresh() {
        guard searchBar != nil, let searchField, let session, searchTask == nil else { return }
        searchRefreshGeneration &+= 1
        let generation = searchRefreshGeneration
        let query = searchField.stringValue
        let grid = session.snapshot()
        let totalPushed = grid.scrollback.totalPushed
        let caseSensitive = ConfigurationStore.shared.configuration.searchCaseSensitive
        let regex = ConfigurationStore.shared.configuration.searchRegex
        searchTask = Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.sweep(
                query, in: grid, caseSensitive: caseSensitive, regex: regex)
            await MainActor.run {
                self?.applySearchResults(
                    outcome, generation: generation, scrollsToMatch: false,
                    totalPushed: totalPushed)
            }
        }
    }

    /// The one place a search sweep's result touches state, and only after
    /// confirming it is still current: superseded by a newer query or
    /// refresh, or the bar closed while it was in flight — either way
    /// `session`/`searchField` may already be gone.
    /// One sweep, whichever mode the bar is in. Pure and `nonisolated` so
    /// both detached tasks call the same thing and the mode decision lives in
    /// one place rather than being duplicated per call site.
    nonisolated static func sweep(
        _ query: String, in grid: Grid, caseSensitive: Bool, regex: Bool
    ) -> SweepOutcome {
        guard regex else {
            return SweepOutcome(
                matches: Search.find(
                    query, in: grid, caseSensitive: caseSensitive,
                    maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled }),
                isInvalidPattern: false, skippedLongLines: 0)
        }
        // An unfinishable pattern is the normal state of one being typed;
        // "no results" is the wrong thing to say about it, so the bar is
        // told the difference (U16).
        guard Search.isValidRegex(query, caseSensitive: caseSensitive) else {
            return SweepOutcome(matches: [], isInvalidPattern: true, skippedLongLines: 0)
        }
        let result = Search.findRegex(
            query, in: grid, caseSensitive: caseSensitive,
            maxMatches: Search.defaultMatchLimit, shouldStop: { Task.isCancelled })
        return SweepOutcome(
            matches: result.matches, isInvalidPattern: false,
            skippedLongLines: result.skippedLongLines)
    }

    /// What one sweep produced, including the two things a plain match list
    /// cannot say: the pattern did not compile, and some lines were too long
    /// to run it against.
    struct SweepOutcome: Sendable {
        var matches: [SelectionRange]
        var isInvalidPattern: Bool
        var skippedLongLines: Int
    }

    private func applySearchResults(
        _ outcome: SweepOutcome, generation: Int, scrollsToMatch: Bool, totalPushed: Int
    ) {
        let matches = outcome.matches
        searchPatternIsInvalid = outcome.isInvalidPattern
        searchSkippedLongLines = outcome.skippedLongLines
        guard generation == searchRefreshGeneration, searchBar != nil else { return }
        // A generation match means this was the last sweep scheduled, so
        // `searchTask` is this (now finished) task.
        searchTask = nil
        searchMatches = matches
        searchMatchesTruncated = matches.count >= Search.defaultMatchLimit
        if searchMatches.isEmpty {
            currentSearchMatchIndex = nil
            currentSearchMatchAnchor = nil
        } else if scrollsToMatch || currentSearchMatchAnchor == nil {
            currentSearchMatchIndex = searchMatches.count - 1
            noteCurrentMatchAnchor(totalPushed: totalPushed)
            scrollToCurrentMatch()
        } else {
            // U12 — the current match keeps its *text*, not its index. Output
            // arriving under an open search bar recomputes the list, and the
            // match that was "7 of 12" is 6 of 13 the moment a line scrolls;
            // keeping the number moved the highlight and the viewport to a
            // different piece of text every time the child printed.
            currentSearchMatchIndex = Self.index(
                closestTo: currentSearchMatchAnchor, in: searchMatches, totalPushed: totalPushed)
            noteCurrentMatchAnchor(totalPushed: totalPushed)
        }
        updateSearchCountLabel()
        invalidateDisplay()
    }

    /// The match nearest a remembered absolute row. Nearest rather than
    /// exact: the line the anchor named may have been evicted from the
    /// scrollback or rewritten by the program, and landing on its neighbour
    /// is what a person reading down a log expects — losing the place
    /// entirely is not.
    static func index(
        closestTo anchor: Int?, in matches: [SelectionRange], totalPushed: Int
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let anchor else { return matches.count - 1 }
        var best = 0
        var bestDistance = Int.max
        for (index, match) in matches.enumerated() {
            let distance = abs((totalPushed + match.start.row) - anchor)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func noteCurrentMatchAnchor(totalPushed: Int) {
        guard let index = currentSearchMatchIndex, searchMatches.indices.contains(index) else {
            currentSearchMatchAnchor = nil
            return
        }
        currentSearchMatchAnchor = totalPushed + searchMatches[index].start.row
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
        searchField?.stringValue = firstLine
        updateSearchResults(scrollsToMatch: true)
    }

    private func stepCurrentMatch(by delta: Int) {
        guard !searchMatches.isEmpty, session != nil else { return }
        let current = currentSearchMatchIndex ?? searchMatches.count - 1
        currentSearchMatchIndex =
            (current + delta + searchMatches.count) % searchMatches.count
        noteCurrentMatchAnchor(totalPushed: session.snapshot().scrollback.totalPushed)
        scrollToCurrentMatch()
        updateSearchCountLabel()
        invalidateDisplay()
    }

    /// Centres the current match vertically. Document row `r` appears at
    /// viewport row `r + scrollOffset`, so the offset that centres it is
    /// `rows/2 - r`; a live-screen match needs no scrolling at all.
    private func scrollToCurrentMatch() {
        guard let index = currentSearchMatchIndex, searchMatches.indices.contains(index),
            session != nil
        else { return }
        let grid = session.snapshot()
        let row = searchMatches[index].start.row
        scrollOffset =
            row >= 0
            ? 0
            : min(grid.scrollback.count, max(0, grid.rows / 2 - row))
    }

    private func updateSearchCountLabel() {
        // The label is the stack view's second arranged view; rebuilding the
        // bar keeps it that way — find it by type, not a stored reference,
        // so the bar's construction stays in one place.
        let label = searchBar?.contentView?.subviews
            .compactMap { $0 as? NSStackView }.first?
            .arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { !($0 is NSSearchField) }
        guard let label else { return }
        if searchPatternIsInvalid {
            // Not "No Results": the pattern never ran, and saying it found
            // nothing would send the user looking for the missing text
            // instead of the missing bracket (U16).
            label.stringValue = L10n.text("search.invalidPattern")
        } else if searchMatches.isEmpty {
            label.stringValue = searchField?.stringValue.isEmpty == false ? "No Results" : ""
        } else if let current = currentSearchMatchIndex {
            // "+" when the sweep stopped at the match cap: the document may
            // hold more matches than were kept (`Search.defaultMatchLimit`).
            // "+" when the sweep stopped at the match cap or skipped a line
            // too long to run a pattern against: either way the document may
            // hold matches that were never counted.
            let incomplete = searchMatchesTruncated || searchSkippedLongLines > 0
            label.stringValue =
                "\(current + 1)/\(searchMatches.count)" + (incomplete ? "+" : "")
        }
    }

    /// U12 — flips `search-case-sensitive` in the config file, which is the
    /// only settings store (`CONFIGURATION.md`), and re-runs the query.
    @objc private func toggleSearchCase(_ sender: Any?) {
        _ = ConfigurationStore.shared.update {
            $0.searchCaseSensitive.toggle()
        }
        if let button = sender as? NSButton { updateCaseButton(button) }
        // The match list changes, so the place is re-found rather than kept:
        // a case-sensitive sweep may not contain the match the user was on.
        currentSearchMatchAnchor = nil
        updateSearchResults(scrollsToMatch: true)
    }

    /// U16 — flips `search-regex` and re-runs the query.
    @objc private func toggleSearchRegex(_ sender: Any?) {
        _ = ConfigurationStore.shared.update { $0.searchRegex.toggle() }
        if let button = sender as? NSButton { updateRegexButton(button) }
        currentSearchMatchAnchor = nil
        updateSearchResults(scrollsToMatch: true)
    }

    private func updateRegexButton(_ button: NSButton) {
        let on = ConfigurationStore.shared.configuration.searchRegex
        button.contentTintColor = on ? .controlAccentColor : SystemAccessibility.secondaryLabelColor
        button.setAccessibilityValue(on ? 1 : 0)
        button.toolTip = L10n.text("search.regex")
    }

    /// State on a borderless icon button has to be legible without colour —
    /// the tint says it at a glance, the accessibility value says it at all.
    private func updateCaseButton(_ button: NSButton) {
        let on = ConfigurationStore.shared.configuration.searchCaseSensitive
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

/// The search field's live updates and its editor's special keys.
extension ViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === searchField else { return }
        updateSearchResults(scrollsToMatch: true)
    }

    /// Return is "next match", Esc closes the bar (the field editor turns it
    /// into `cancelOperation:`, which never reaches `keyDown`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        guard control === searchField else { return false }
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
