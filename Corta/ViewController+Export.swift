import AppKit
import CortaTerminal
import UniformTypeIdentifiers

/// U15 — writing what is in the pane to a file.
///
/// **Why a file and not just the clipboard.** ⌘C already exists, and for a
/// line or two it is the right tool. A hundred thousand lines of build output
/// is not something anybody wants on the pasteboard on the way to a bug
/// report: it has to survive the next copy, be attachable, and be greppable.
/// This is the same text the clipboard would get — `Selection.text` over the
/// same range, so a soft-wrapped line exports as one line exactly as it
/// copies as one — written where the user says.
///
/// **What gets written.** The selection if there is one, the whole document
/// (scrollback plus screen) if there is not. That is the rule the Edit menu's
/// Copy already follows one level down, and it means the command needs no
/// second name and no submenu: what you have selected is what you get.
extension ViewController {
    @objc func exportText(_ sender: Any?) {
        guard isOperable, let window = view.window else { return }
        let grid = session.snapshot()
        let hasSelection = selection != nil
        let text = Self.exportableText(grid: grid, selection: selection.map {
            selectionRange(for: $0, in: grid)
        })
        guard !text.isEmpty else {
            terminalView?.showToast(L10n.text("toast.nothingToExport"), kind: .warning)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = Self.exportFilename(hasSelection: hasSelection)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = L10n.text(
            hasSelection ? "export.message.selection" : "export.message.history")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.terminalView?.showToast(L10n.text("toast.exported"))
            } catch {
                // The panel already granted access, so a failure here is a
                // full disk or a read-only volume — worth an alert rather
                // than a toast, because the file the user asked for does not
                // exist and nothing else would say so.
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// The text a save would write: the selection, or the whole document.
    ///
    /// Static and pure so the range arithmetic is testable without a window
    /// or a save panel — the part that can be wrong is which rows are chosen,
    /// not that `NSSavePanel` works.
    static func exportableText(grid: Grid, selection: SelectionRange?) -> String {
        if let selection { return Selection.text(of: selection, in: grid) }
        // The whole document, the same range ⌘A builds: the scrollback
        // counts backwards from the live screen, so its first row is
        // `-scrollback.count`.
        let whole = SelectionRange(
            anchor: SelectionPoint(row: -grid.scrollback.count, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1))
        return Selection.text(of: whole, in: grid)
    }

    /// A name that says what the file is and when it was taken, so a folder
    /// of them is still readable a week later.
    static func exportFilename(hasSelection: Bool, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let kind = hasSelection ? "Selection" : "History"
        return "Corta \(kind) \(formatter.string(from: date)).txt"
    }
}
