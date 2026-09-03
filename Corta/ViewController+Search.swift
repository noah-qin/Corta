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
        countLabel.textColor = SystemAccessibility.tertiaryLabelColor
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

        let stack = NSStackView(views: [
            glass, field, countLabel, separator,
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
        stack.setCustomSpacing(6, after: stack.views[5])
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
        // Reduce Transparency is not "less translucent", it is "background
        // content must not show through" — so the glass gets an opaque tint
        // rather than a lowered alpha. The bar keeps its shape and its
        // position; what changes is that the terminal text behind it stops
        // competing with the query the user is typing.
        if SystemAccessibility.reduceTransparency {
            bar.tintColor = .windowBackgroundColor
        }
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
