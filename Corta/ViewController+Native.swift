import Cocoa
import CortaTerminal

/// M6.15, controller side: what the pane does with a dropped file, a force
/// touch and a Services request.
extension ViewController {
    /// Wired in `viewDidLoad`.
    func installNativeIntegrations(on view: TerminalView) {
        view.onDropPaths = { [weak self] paths in
            self?.insertDroppedPaths(paths)
        }
        view.onLookUp = { [weak self] point in
            self?.wordForLookUp(at: point)
        }
        view.onServicesSelection = { [weak self] in
            self?.selectedText()
        }
        view.onServicesInsert = { [weak self] text in
            self?.insertAsPaste(text)
        }
    }

    /// A dropped path arrives at the prompt as text, shell-quoted, exactly
    /// as if it had been typed. Multiple files are one space-separated run,
    /// which is what a command taking several arguments wants.
    private func insertDroppedPaths(_ paths: [String]) {
        let text = paths.map(Self.shellQuoted).joined(separator: " ")
        guard !text.isEmpty else { return }
        // No trailing space: the user may want to keep typing the path, and
        // a space is one keystroke away either way.
        insertAsPaste(text)
    }

    /// POSIX single-quoting: everything inside `'…'` is literal, and the
    /// only character that cannot appear there is `'` itself, which is
    /// written by closing the quote, escaping one apostrophe and reopening.
    ///
    /// A path is attacker-influenceable — a filename can contain `;`,
    /// backticks, `$(…)` — and this is text going *to* a shell, so quoting
    /// is not cosmetic. An unquoted drop of a maliciously named file would
    /// be a command waiting for a Return.
    static func shellQuoted(_ path: String) -> String {
        // A path of only safe characters reads better unquoted, and the set
        // is deliberately narrow: anything outside it gets the quotes.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@:+")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Text from a drop or a service goes to the child down the paste path,
    /// so bracketed paste applies and the child can tell it apart from
    /// typing. The multi-line warning does not: the user did not paste, and
    /// a dropped path has no newline in it to begin with.
    func insertAsPaste(_ text: String) {
        guard session != nil, !text.isEmpty else { return }
        session.write(
            Paste.bytes(for: text, bracketedPasteEnabled: session.isBracketedPasteEnabled))
    }

    /// The current selection as plain text, for the Services menu.
    func selectedText() -> String? {
        guard let selection, session != nil else { return nil }
        let grid = session.snapshot()
        let text = Selection.text(of: selectionRange(for: selection, in: grid), in: grid)
        return text.isEmpty ? nil : text
    }

    /// The word under a force touch, and the point to anchor the dictionary
    /// popover at — the cell's own origin, so the popover points at the word
    /// rather than at the pointer.
    func wordForLookUp(at point: CGPoint) -> (String, CGPoint)? {
        guard session != nil else { return nil }
        let grid = session.snapshot()
        let position = Self.documentPosition(
            for: point, viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, grid: grid,
            scrollOffset: scrollOffset, topInset: topInset)
        let range = Selection.range(at: position, unit: .word, in: grid)
        let text = Selection.text(of: range, in: grid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let metrics = terminalRenderer.pointMetrics
        let origin = CGPoint(
            x: TerminalLayout.insets.left + CGFloat(range.start.column) * metrics.cellWidth,
            y: point.y)
        return (text, origin)
    }
}
