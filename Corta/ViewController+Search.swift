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
        let flags = event.modifierFlags.intersection([.command, .shift])
        guard flags.contains(.command),
            let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        switch characters {
        case "f":
            showSearchBar()
            return true
        case "g" where searchBar != nil:
            if flags.contains(.shift) { showPreviousMatch() } else { showNextMatch() }
            return true
        default:
            return false
        }
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

        let field = NSSearchField()
        field.placeholderString = "Find"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        // The glass pill *is* the container. Left bezelled, the field drew a
        // second rounded rect (and its own focus ring) inside the first.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor

        func button(_ symbolName: String, _ description: String, _ action: Selector) -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbolName, accessibilityDescription: description)!,
                target: self, action: action)
            button.isBordered = false
            return button
        }

        let stack = NSStackView(views: [
            field, countLabel,
            button("chevron.up", "Previous Match", #selector(searchBarPrevious(_:))),
            button("chevron.down", "Next Match", #selector(searchBarNext(_:))),
            button("xmark", "Close Find", #selector(searchBarClose(_:))),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSGlassEffectView()
        bar.cornerRadius = 12
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
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(
                equalTo: view.topAnchor, constant: windowChrome + 6),
        ])

        searchBar = bar
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
        searchBar?.removeFromSuperview()
        searchBar = nil
        searchField = nil
        if let searchKeyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
            self.searchKeyMonitor = nil
        }
        searchMatches = []
        currentSearchMatchIndex = nil
        if let beforeSearch = scrollOffsetBeforeSearch {
            scrollOffset = beforeSearch
            scrollOffsetBeforeSearch = nil
        }
        invalidateDisplay()
        view.window?.makeFirstResponder(terminalView)
    }

    // MARK: - Matching

    /// Re-runs the query against a fresh snapshot. Called on every keystroke
    /// and on output while the bar is open — matches are recomputed, never
    /// incrementally patched (the core's logical-line pass over a full
    /// scrollback is one lazy sweep, `Search.swift`). `scrollsToMatch`
    /// distinguishes a fresh query, which jumps to the newest match — the
    /// one a shell user just watched print — from a background refresh,
    /// which keeps the user's place.
    func updateSearchResults(scrollsToMatch: Bool) {
        guard searchBar != nil, let searchField, session != nil else { return }
        let grid = session.snapshot()
        searchMatches = Search.find(searchField.stringValue, in: grid)
        if searchMatches.isEmpty {
            currentSearchMatchIndex = nil
        } else if scrollsToMatch || currentSearchMatchIndex == nil {
            currentSearchMatchIndex = searchMatches.count - 1
            scrollToCurrentMatch()
        } else if let current = currentSearchMatchIndex, current >= searchMatches.count {
            currentSearchMatchIndex = searchMatches.count - 1
        }
        updateSearchCountLabel()
        invalidateDisplay()
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
        guard !searchMatches.isEmpty else { return }
        let current = currentSearchMatchIndex ?? searchMatches.count - 1
        currentSearchMatchIndex =
            (current + delta + searchMatches.count) % searchMatches.count
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
        if searchMatches.isEmpty {
            label.stringValue = searchField?.stringValue.isEmpty == false ? "No Results" : ""
        } else if let current = currentSearchMatchIndex {
            label.stringValue = "\(current + 1)/\(searchMatches.count)"
        }
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
