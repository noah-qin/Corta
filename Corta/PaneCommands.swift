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
import UniformTypeIdentifiers

/// What a pane's commands act on.
protocol PaneCommandsHost: AnyObject {
    var session: TerminalSession! { get }
    /// False for a pane whose setup failed.
    var isOperable: Bool { get }
    var view: NSView { get }
    var terminalView: TerminalView! { get }
    var terminalRenderer: TerminalRenderer! { get }
    var splitController: SplitViewController? { get }
    var selection: TerminalSelection? { get set }
    var scrollOffset: Int { get set }
    var topInset: CGFloat { get }
    var didTeardown: Bool { get }
    var isFocusedPane: Bool { get }
    /// The command copy, export and open-reference act on.
    var effectiveCommand: CommandRecord? { get }
    var remote: PaneRemote { get }
    var fontSize: CGFloat { get }
    var isFontSizeZoomed: Bool { get set }
    func invalidateDisplay()
    func setFontSize(_ newSize: CGFloat, settle: Bool)
    /// Ends a gesture's run of unsettled font sizes.
    func settleFontChange()
    /// Selection geometry and the viewport's return to the live screen.
    var pointer: PanePointer { get }
}

/// The commands a pane answers from the menu, the palette and its own
/// context menu: font size and pinch, copy, paste and export, drops,
/// Services and Look Up, the Finder actions, app-initiated `cd`, and
/// Clear Screen, Clear History and Reset Terminal.
///
/// The pane forwards its actions here (`ViewController.forwardingTarget`),
/// and its `validateMenuItem` asks this one for the items it owns.
final class PaneCommands: NSObject, NSMenuItemValidation {
    weak var host: PaneCommandsHost?

    /// An O(scrollback) copy/export build, off the interaction path. Cancelling
    /// only stops its result being applied — the build runs to completion — and
    /// `largeTextTaskGeneration` keeps a late one from clearing its successor.
    var largeTextTask: Task<Void, Never>?
    var largeTextTaskGeneration = 0
    /// What copy, paste and Copy Path use: the system clipboard unless the
    /// pane is given another.
    let pasteboard: NSPasteboard
    /// How a copy builds its text, on the detached task: `Selection.text`.
    /// Given, so a caller can hold the build at a known point — the task has
    /// no scheduling barrier of its own.
    private let buildSelectionText: @Sendable (SelectionRange, Grid) -> String
    /// Pinch magnification not yet spent on a whole point.
    private var pinchAccumulator: CGFloat = 0
    /// The current pinch changed the size, so its end settles the window.
    private var pinchChangedSize = false

    init(
        host: PaneCommandsHost? = nil, pasteboard: NSPasteboard = .general,
        buildSelectionText: @escaping @Sendable (SelectionRange, Grid) -> String =
            Selection.text(of:in:)
    ) {
        self.host = host
        self.pasteboard = pasteboard
        self.buildSelectionText = buildSelectionText
    }

    /// The pane closed: a build in flight must not land.
    func stop() {
        largeTextTask?.cancel()
        largeTextTask = nil
    }

    // MARK: - Context menu

    /// The right-click menu: editing and split actions, with explicit targets
    /// so it also works when shown programmatically.
    func contextMenu(bindings suppliedBindings: Keybindings? = nil) -> NSMenu {
        let menu = NSMenu()
        let bindings = suppliedBindings ?? ConfigurationStore.shared.configuration.keybindings
        func item(_ command: TerminalCommand, _ target: AnyObject?, title: String? = nil, enabled: Bool = true) {
            let shortcut = bindings[command]
            let menuItem = NSMenuItem(
                title: title ?? command.title, action: command.action,
                keyEquivalent: shortcut?.menuKeyEquivalent ?? "")
            menuItem.keyEquivalentModifierMask = shortcut?.menuModifierMask ?? []
            menuItem.target = target
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        item(.copy, self, enabled: host?.selection != nil)
        item(.paste, host)
        item(.selectAll, host)
        item(.newTab, NSApp.delegate)
        if let splitController = host?.splitController {
            menu.addItem(.separator())
            item(.splitRight, splitController)
            item(.splitDown, splitController)
            item(.renameTab, splitController)
            let closeTitle = L10n.text(splitController.hasMultiplePanes ? "menu.closePane" : "menu.closeWindow")
            item(.close, splitController, title: closeTitle)
        }
        return menu
    }

    // MARK: - Font size

    /// ⌘= / ⌘- / ⌘0 apply to every pane: they share one cell geometry
    /// (`SplitViewController.setFontSizeForAllPanes`).
    @objc func increaseFontSize(_ sender: Any?) {
        guard let host else { return }
        applyFontSizeForAllPanes(host.fontSize + 1, isZoomed: true, settle: true)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        guard let host else { return }
        applyFontSizeForAllPanes(host.fontSize - 1, isZoomed: true, settle: true)
    }

    /// Ends the zoom at the config file's current size, as a new window would
    /// open.
    @objc func resetFontSize(_ sender: Any?) {
        let configured = CGFloat(ConfigurationStore.shared.configuration.fontSize)
        applyFontSizeForAllPanes(configured, isZoomed: false, settle: true)
    }

    /// Pinch zoom, spent one whole point at a time so it lands on ⌘+/⌘−'s
    /// steps: each size is an atlas rebuild. The grid follows through the
    /// drag debounce and the window is fitted once, when the pinch ends.
    func magnify(by magnification: CGFloat) {
        guard let host else { return }
        let sizes = Self.fontSizes(
            forMagnification: magnification,
            accumulator: &pinchAccumulator,
            startingAt: host.fontSize)
        for size in sizes {
            applyFontSizeForAllPanes(size, isZoomed: true, settle: false)
            pinchChangedSize = true
        }
    }

    /// The pure step accumulator, for tests.
    nonisolated static func fontSizes(
        forMagnification magnification: CGFloat,
        accumulator: inout CGFloat,
        startingAt fontSize: CGFloat
    ) -> [CGFloat] {
        accumulator += magnification
        // Per point: a deliberate pinch resizes, resting fingers don't.
        let step: CGFloat = 0.15
        var current = fontSize
        var sizes: [CGFloat] = []
        while abs(accumulator) >= step {
            let direction: CGFloat = accumulator > 0 ? 1 : -1
            accumulator -= direction * step
            let target = current + direction
            // Don't fill at the clamp, or reversing fires a burst of rebuilds.
            guard target >= 8, target <= 64 else {
                accumulator = 0
                return sizes
            }
            sizes.append(target)
            current = target
        }
        return sizes
    }

    /// The next pinch starts from zero; this one's size settles.
    func endMagnification() {
        pinchAccumulator = 0
        guard pinchChangedSize, let host else { return }
        pinchChangedSize = false
        if let splitController = host.splitController {
            splitController.settleFontChangeForAllPanes()
        } else {
            host.settleFontChange()
        }
    }

    /// A zoom is a per-window size that never touches the config file:
    /// writing the global default would resize every window on the next
    /// config change. `configurationChanged` skips the size while
    /// `isFontSizeZoomed`, and `resetFontSize` ends it. New panes inherit the
    /// window's temporary zoom.
    private func applyFontSizeForAllPanes(_ newSize: CGFloat, isZoomed: Bool, settle: Bool) {
        guard let host else { return }
        if let splitController = host.splitController {
            splitController.setFontSizeForAllPanes(newSize, isZoomed: isZoomed, settle: settle)
        } else {
            host.setFontSize(newSize, settle: settle)
            host.isFontSizeZoomed = isZoomed
        }
    }

    // MARK: - Pinch, paste, drops, Services and Look Up

    func installNativeIntegrations(on view: TerminalView) {
        view.onMagnify = { [weak self] magnification in
            self?.magnify(by: magnification)
        }
        view.onMagnifyEnded = { [weak self] in
            self?.endMagnification()
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
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

    /// Dropped paths arrive at the prompt shell-quoted, as if typed.
    private func insertDroppedPaths(_ paths: [String]) {
        let text = Self.quotedDropText(paths)
        guard !text.isEmpty else { return }
        // No trailing space: the user may keep typing the path.
        insertAsPaste(text)
    }

    /// One space-separated, quoted run. Each path is sanitised first (a name
    /// can hold ESC or a newline); an emptied path is dropped.
    static func quotedDropText(_ paths: [String]) -> String {
        paths.map { Paste.sanitized($0) }
            .filter { !$0.isEmpty }
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    /// Single-quoted for any shell the pane may be running. Filenames can
    /// carry `;`, backticks or `$(…)`, and this text goes to a shell, so
    /// quoting makes the printable remainder inert (controls are already
    /// gone). Not POSIX's `'\''`: inside fish's single quotes `\'` and `\\`
    /// are escapes, so `x\'; cmd; \'` broke out and ran `cmd`. `'` and `\`
    /// are each written double-quoted between single-quoted runs — `"'"` and
    /// `"\\"` read the same in sh, bash, zsh and fish.
    static func shellQuoted(_ path: String) -> String {
        // A deliberately narrow set may go unquoted.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@:+")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        var quoted = "'"
        for character in path {
            switch character {
            case "'": quoted += #"'"'"'"#
            case "\\": quoted += #"'"\\"'"#
            default: quoted.append(character)
            }
        }
        return quoted + "'"
    }

    /// Drops and Services go down the ⌘V path (`SECURITY.md` §2.3): C0
    /// stripped, bracketed paste when asked, and a newline warning without
    /// `?2004` — service text and filenames can hold newlines.
    func insertAsPaste(_ text: String) {
        guard let host, host.session != nil else { return }
        let sanitized = Paste.sanitized(text)
        guard !sanitized.isEmpty else { return }
        guard Paste.needsWarning(text: sanitized, bracketedPasteEnabled: bracketedPasteEnabled()) else {
            pasteNow(sanitized)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("paste.newlines.title")
        alert.informativeText = L10n.text("paste.newlines.message")
        alert.addButton(withTitle: L10n.text("common.paste"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.present(for: host.view.window) { [weak self] response in
            // The pane may have closed while the sheet was up.
            guard response == .alertFirstButtonReturn, self?.host?.session != nil else { return }
            self?.pasteNow(sanitized)
        }
    }

    /// A paste in every way that matters, as in `pasteFromClipboard` —
    /// including saying so when the child is not reading, rather than
    /// dropping the drop without a word.
    private func pasteNow(_ sanitized: String) {
        host?.pointer.returnToBottomOnInput()
        sendPaste(sanitized)
    }

    /// The selection's text, or nil when there is none or it is empty.
    func selectedText() -> String? {
        guard let host, let selection = host.selection, let session = host.session else {
            return nil
        }
        let grid = session.snapshot()
        let text = Selection.text(of: host.pointer.selectionRange(for: selection, in: grid), in: grid)
        return text.isEmpty ? nil : text
    }

    /// The word under a force touch, anchored at the cell's origin so the
    /// popover points at the word.
    func wordForLookUp(at point: CGPoint) -> (String, CGPoint)? {
        guard let host, let session = host.session, let terminalRenderer = host.terminalRenderer,
            let terminalView = host.terminalView
        else { return nil }
        let grid = session.snapshot()
        let metrics = terminalRenderer.pointMetrics
        let position = PanePointer.documentPosition(
            for: point, viewHeight: terminalView.bounds.height,
            metrics: metrics, grid: grid,
            scrollOffset: host.scrollOffset, topInset: host.topInset)
        let range = Selection.range(at: position, unit: .word, in: grid)
        let text = Selection.text(of: range, in: grid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let origin = CGPoint(
            x: TerminalLayout.insets.left + CGFloat(range.start.column) * metrics.cellWidth,
            y: point.y)
        return (text, origin)
    }

    // MARK: - Copy

    /// ⌘C through the responder chain; never reaches the PTY. The text build
    /// is O(selection) — the whole document for ⌘A — so it runs off the main
    /// actor on `largeTextTask`, like `exportText(_:)`.
    @objc func copy(_ sender: Any?) {
        guard let host, let selection = host.selection, let session = host.session else { return }
        let grid = session.snapshot()
        let range = host.pointer.selectionRange(for: selection, in: grid)
        // The pasteboard is shared by every pane and app: recheck `changeCount`
        // before writing so a slow copy never clobbers a newer write.
        let changeCountAtStart = pasteboard.changeCount
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // `.detached`, so the build is off the main actor by construction
        // rather than by inference; the pasteboard write hops back.
        let buildText = buildSelectionText
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text = buildText(range, grid)
            await MainActor.run {
                // Only this generation may clear the handle a newer copy installed.
                guard let self, self.host?.didTeardown == false,
                    self.largeTextTaskGeneration == generation
                else { return }
                self.largeTextTask = nil
                guard !Task.isCancelled, !text.isEmpty else { return }
                let pasteboard = self.pasteboard
                guard pasteboard.changeCount == changeCountAtStart else {
                    // Someone wrote since; their write is newer than this selection.
                    return
                }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Confirm only a write that happened: copy-on-select is never silent.
                self.host?.terminalView?.showToast(L10n.text("toast.copied"))
            }
        }
    }

    // MARK: - Export

    /// Writes the pane to a file, for output too large for the pasteboard.
    /// The text is `Selection.text`, exactly what a copy gets: the selection
    /// if there is one, else the whole document.
    ///
    /// The build is O(scrollback) — hundreds of ms for 100k lines
    /// (`PERFORMANCE.md` §5.2) — so it runs off the main thread, before the
    /// save panel, so empty text skips the panel. `largeTextTask` is cancelled
    /// by a newer export or `stop()`, which stops the panel and write that
    /// follow; a row walk in progress still finishes.
    @objc func exportText(_ sender: Any?) {
        guard let host, host.isOperable, let window = host.view.window else { return }
        let grid = host.session.snapshot()
        let selection = host.selection
        let range = selection.map { host.pointer.selectionRange(for: $0, in: grid) }
        performExport(
            window: window, grid: grid, range: range,
            messageKey: selection != nil ? "export.message.selection" : "export.message.history",
            filename: Self.exportFilename(hasSelection: selection != nil))
    }

    /// The same export for `effectiveCommand`'s output.
    @objc func exportCommandOutput(_ sender: Any?) {
        guard let host, host.isOperable, let window = host.view.window else { return }
        let grid = host.session.snapshot()
        guard let range = PaneShellIntegration.commandOutputRange(grid: grid, record: host.effectiveCommand)
        else {
            host.terminalView?.showToast(L10n.text("toast.noCommandOutput"), kind: .warning)
            return
        }
        performExport(
            window: window, grid: grid, range: range, messageKey: "export.message.command",
            filename: Self.exportFilename(kind: "Command Output"))
    }

    /// The flow both exports share (see `exportText`).
    private func performExport(
        window: NSWindow, grid: Grid, range: SelectionRange?, messageKey: String, filename: String
    ) {
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // Detached, as in `copy(_:)`; AppKit calls hop back to the main actor
        // explicitly.
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text = Self.exportableText(grid: grid, selection: range)

            enum Outcome {
                case cancelledOrDismissed
                case empty
                case wrote
                case failed(Error)
            }
            let outcome: Outcome
            if Task.isCancelled {
                outcome = .cancelledOrDismissed
            } else if text.isEmpty {
                outcome = .empty
            } else {
                // Lets cancellation dismiss the panel and resume at once; the
                // continuation alone has no cancellation awareness.
                let panelBox = PresentedPanelBox()
                let url: URL? = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            guard let self, self.host?.didTeardown == false,
                                self.largeTextTaskGeneration == generation
                            else {
                                continuation.resume(returning: nil)
                                return
                            }
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.plainText]
                            panel.nameFieldStringValue = filename
                            panel.canCreateDirectories = true
                            panel.isExtensionHidden = false
                            panel.message = L10n.text(messageKey)
                            panelBox.panel = panel
                            panel.beginSheetModal(for: window) { response in
                                continuation.resume(returning: response == .OK ? panel.url : nil)
                            }
                        }
                    }
                } onCancel: {
                    // Accepted race: `onCancel` can run before the panel is
                    // stored, and then the panel still shows. Closing it needs an
                    // atomic handoff not worth it for a window this small.
                    Task { @MainActor in
                        guard let panel = panelBox.panel else { return }
                        window.endSheet(panel, returnCode: .cancel)
                    }
                }
                if Task.isCancelled {
                    outcome = .cancelledOrDismissed
                } else if let url {
                    do {
                        try Self.write(text, to: url)
                        outcome = .wrote
                    } catch {
                        // Access was granted, so this is a full disk or read-only
                        // volume: alert, since the file doesn't exist.
                        outcome = .failed(error)
                    }
                } else {
                    outcome = .cancelledOrDismissed
                }
            }

            // One exit: clear the handle (generation-guarded) and apply.
            await MainActor.run {
                guard let self, self.host?.didTeardown == false,
                    self.largeTextTaskGeneration == generation
                else { return }
                self.largeTextTask = nil
                switch outcome {
                case .cancelledOrDismissed:
                    break
                case .empty:
                    self.host?.terminalView?.showToast(
                        L10n.text("toast.nothingToExport"), kind: .warning)
                case .wrote:
                    self.host?.terminalView?.showToast(L10n.text("toast.exported"))
                case .failed(let error):
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// The write, testable apart from the panel: UTF-8 with a trailing
    /// newline, which grep, less and diff expect.
    nonisolated static func write(_ text: String, to url: URL) throws {
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    /// The selection or the whole document; pure, for tests.
    nonisolated static func exportableText(grid: Grid, selection: SelectionRange?) -> String {
        if let selection { return Selection.text(of: selection, in: grid) }
        // As ⌘A: the scrollback's first row is `-scrollback.count`.
        let whole = SelectionRange(
            anchor: SelectionPoint(row: -grid.scrollback.count, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1))
        return Selection.text(of: whole, in: grid)
    }

    nonisolated static func exportFilename(hasSelection: Bool, date: Date = Date()) -> String {
        exportFilename(kind: hasSelection ? "Selection" : "History", date: date)
    }

    nonisolated static func exportFilename(kind: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Corta \(kind) \(formatter.string(from: date)).txt"
    }

    // MARK: - Finder and the working directory

    /// `session.workingDirectory` is nil when remote or unreported
    /// (`Performer+OSC.swift`). No outbound drag: it would need a new drag
    /// gesture beside selection dragging; Reveal and Copy Path cover the
    /// need with existing APIs.
    var knownWorkingDirectory: String? {
        guard let host, host.isOperable else { return nil }
        return host.session.workingDirectory
    }

    var hasKnownWorkingDirectory: Bool { knownWorkingDirectory != nil }

    @objc func revealWorkingDirectoryInFinder(_ sender: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// Copies the path, confirmed by toast.
    @objc func copyWorkingDirectoryPath(_ sender: Any?) {
        guard let directory = knownWorkingDirectory else {
            host?.terminalView?.showToast(L10n.text("toast.noWorkingDirectory"), kind: .warning)
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(directory, forType: .string)
        host?.terminalView?.showToast(L10n.text("toast.copiedWorkingDirectory"))
    }

    /// `cd ..` through the gated `changeDirectory(to:)`. Reads
    /// `shellDirectory`, so a remote pane walks its own directories; spawns and
    /// the project-root search use the local-only `session.workingDirectory`.
    @objc func changeDirectoryToParent(_ sender: Any?) {
        guard let directory = shellDirectory?.path else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        changeDirectory(to: parent)
    }

    /// `cd` to the nearest `.git` ancestor, same gate; no ancestor is
    /// reported, never guessed.
    @objc func changeDirectoryToProjectRoot(_ sender: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        withProjectRoot(of: directory) { commands, root in
            commands.changeDirectory(to: root)
        }
    }

    /// Splits with a new pane rooted at the parent directory.
    @objc func openParentDirectoryInNewPane(_ sender: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        host?.splitController?.splitFocusedPane(orientation: .columns, workingDirectory: parent)
    }

    @objc func openProjectRootInNewPane(_ sender: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        withProjectRoot(of: directory) { commands, root in
            commands.host?.splitController?.splitFocusedPane(
                orientation: .columns, workingDirectory: root)
        }
    }

    /// Finds `directory`'s project root off the main thread — the walk
    /// `stat`s a child-reported path, which can sit on an unreachable
    /// automount — then runs `body` on it, or reports that there is none.
    private func withProjectRoot(
        of directory: String, _ body: @escaping @MainActor (PaneCommands, String) -> Void
    ) {
        Task { [weak self] in
            let root = await Task.detached(priority: .userInitiated) {
                DirectoryHistory.projectRoot(for: directory)
            }.value
            // The lookup can outlast a change of focus; the toast or split
            // would then land on another pane.
            guard let self, let host, !host.didTeardown, host.isFocusedPane else { return }
            guard let root else {
                host.terminalView?.showToast(L10n.text("toast.noProjectRoot"), kind: .warning)
                return
            }
            body(self, root)
        }
    }

    // MARK: - App-initiated `cd`

    /// Whether this pane can safely receive an app-initiated `cd` now:
    ///
    /// - **Pane identity**: a live session (`isOperable`).
    /// - **Remote context**: a remote path is fine for the pane's own remote
    ///   shell. It must never reach a local spawn, which is structural:
    ///   spawns read `session.workingDirectory`, kept local-only by
    ///   `Performer+OSC.swift`, while remote reports live in `remoteContext`.
    /// - **Prompt state**: `hasShellIntegration` and `!isCommandRunning` — a
    ///   busy shell or a TUI must not get prompt input.
    /// - **Existing input**: the cursor is still at `promptEndPosition`, so
    ///   nothing the user typed gets a `cd` spliced into it.
    var canChangeDirectorySafely: Bool {
        guard let host, host.isOperable, let session = host.session,
            session.hasShellIntegration, !session.isCommandRunning
        else {
            return false
        }
        guard let end = session.promptEndPosition else { return false }
        let grid = session.snapshot()
        guard let screenRow = grid.screenRow(ofAbsoluteRow: end.row) else { return false }
        return grid.cursor.row == screenRow && grid.cursor.column == end.column
    }

    /// Where this pane's shell actually is: local when local, the reported
    /// remote directory (with host) when remote, nil when neither is known.
    /// Only for `changeDirectory(to:)`; local spawns and Finder read
    /// `session.workingDirectory`.
    var shellDirectory: (path: String, host: String?)? {
        guard let host else { return nil }
        switch host.remote.state {
        case .remote(let remoteHost, let directory, _):
            return (directory, remoteHost)
        case .local:
            return host.session?.workingDirectory.map { ($0, nil) }
        case .remoteUnknown, .unknown:
            // Remote without a report, or a multiplexer: the local directory is
            // stale, and sending it to another machine's shell is a leak.
            return nil
        }
    }

    /// Writes `cd '<path>'` and Return under `canChangeDirectorySafely`;
    /// returns whether it did.
    ///
    /// The path began as child-sent OSC 7 text, which `SECURITY.md` §6 says
    /// never to write back. It goes back only as the user's command: sent on
    /// their own action to the shell on the path's machine, quoted for any
    /// shell (`shellQuoted` — fish reads `'\''` differently), and refused
    /// outright if it holds a control character, the one shape another shell
    /// could read as two commands.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely, Self.isSendableDirectoryPath(path),
            let session = host?.session
        else { return false }
        session.write(Array("cd \(Self.shellQuoted(path))\r".utf8))
        return true
    }

    /// Non-empty, with nothing from C0 or C1.
    nonisolated static func isSendableDirectoryPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            }
    }

    // MARK: - Paste

    /// ⌘V: the one paste path drops and Services also take
    /// (`insertAsPaste`).
    func pasteFromClipboard() {
        guard let text = pasteboard.string(forType: .string) else { return }
        insertAsPaste(text)
    }

    /// Queues a sanitised paste whole, or not at all. In pieces, a backlog
    /// that filled part-way stopped it after `ESC[200~` and before
    /// `ESC[201~`, and the shell — Claude Code, zsh — stayed in paste mode,
    /// taking every later Return as pasted text: the pane looked frozen.
    func sendPaste(_ sanitized: String) {
        let payload = Paste.bytes(for: sanitized, bracketedPasteEnabled: bracketedPasteEnabled())
        // Chunks, so the writer hands the child one at a time.
        guard let session = host?.session else { return }
        switch session.write(chunks: Paste.chunked(payload)) {
        case .accepted:
            break
        case .backpressured:
            // The child stopped reading; nothing was sent. Say why.
            host?.terminalView?.showToast(L10n.text("toast.pasteStopped"), kind: .warning)
        case .stopped:
            // The session is gone; nobody would read the toast.
            break
        }
    }

    /// ⌘V, and the context menu.
    @objc func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    /// ?2004: wrap pastes in `ESC[200~`…`ESC[201~`, skip the newline warning.
    func bracketedPasteEnabled() -> Bool {
        host?.session?.isBracketedPasteEnabled ?? false
    }

    // MARK: - Clear and reset

    /// Clear Screen, Clear History and Reset Terminal — three names because
    /// "clear" means something different everywhere, and the menu says what
    /// each discards:
    ///
    /// | Command | Screen | Scrollback | Modes, colours, cursor |
    /// | --- | --- | --- | --- |
    /// | Clear Screen | erased | kept | kept |
    /// | Clear History | kept | discarded | kept |
    /// | Reset Terminal | erased | discarded | reset |
    ///
    /// They act on the grid, never the child: `\u{1B}c` written to the
    /// child's input would be typed characters (`SECURITY.md` §6). The child is
    /// never told, so running jobs are undisturbed; `vim` redraws on its next
    /// frame, a shell on ⌃L or Return.
    @objc func clearScreen(_ sender: Any?) {
        applyTerminalState(.clearScreen, notice: "toast.clearedScreen")
    }

    @objc func clearHistory(_ sender: Any?) {
        confirmDiscardingHistory(titleKey: "clear.history.title") { [weak self] in
            self?.applyTerminalState(.clearHistory, notice: "toast.clearedHistory")
        }
    }

    @objc func resetTerminal(_ sender: Any?) {
        confirmDiscardingHistory(titleKey: "clear.reset.title") { [weak self] in
            self?.applyTerminalState(.reset, notice: "toast.resetTerminal")
        }
    }

    /// Asks before discarding history, which can't be undone — never for Clear
    /// Screen or an empty scrollback, so the dialog keeps its meaning. States
    /// the line count. Honours `confirm-close` rather than a second key. A
    /// sheet on the pane's window; `proceed` runs once confirmed, or at once
    /// when nothing needs asking.
    private func confirmDiscardingHistory(
        titleKey: String, then proceed: @escaping @MainActor () -> Void
    ) {
        guard let host, host.isOperable, ConfigurationStore.shared.configuration.confirmClose
        else { return proceed() }
        let lines = host.session.snapshot().scrollback.count
        guard lines > 0 else { return proceed() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(titleKey)
        alert.informativeText = L10n.format("clear.history.detail", lines)
        alert.addButton(withTitle: L10n.text("clear.history.discard"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.present(for: host.view.window) { [weak self] response in
            guard response == .alertFirstButtonReturn, self?.host?.isOperable == true else { return }
            proceed()
        }
    }

    /// Applies the command, then drops a selection or viewport pointing into
    /// discarded history (which would highlight the wrong text or show
    /// nothing), and confirms with a toast.
    private func applyTerminalState(
        _ command: TerminalSession.TerminalStateCommand, notice: String
    ) {
        guard let host, host.isOperable else { return }
        host.session.apply(command)
        host.selection = nil
        host.scrollOffset = 0
        host.invalidateDisplay()
        host.terminalView?.noteAccessibilityValueChanged()
        host.terminalView?.noteAccessibilitySelectionChanged()
        host.terminalView?.showToast(L10n.text(notice))
    }

    // MARK: - Menu validation

    /// Greys out what this pane cannot do now: a disabled item says "not
    /// here" where a beep says nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(exportCommandOutput(_:)):
            guard let host, host.isOperable else { return false }
            return PaneShellIntegration.commandOutputText(
                grid: host.session.snapshot(), record: host.effectiveCommand) != nil
        case #selector(exportText(_:)):
            return host?.isOperable == true
        case #selector(revealWorkingDirectoryInFinder(_:)), #selector(copyWorkingDirectoryPath(_:)),
            #selector(openParentDirectoryInNewPane(_:)):
            return hasKnownWorkingDirectory
        case #selector(changeDirectoryToParent(_:)):
            // `shellDirectory` is nil exactly when there is no honest answer.
            return shellDirectory != nil && canChangeDirectorySafely
        // Not whether a root exists: finding one walks the path with a `stat`
        // per level, and the path is the child's — `/net/<host>/…` mounts on
        // first touch, and validation runs on the main thread each time a
        // menu opens. The action looks, off the main thread, and says so
        // when there is none.
        case #selector(changeDirectoryToProjectRoot(_:)):
            return hasKnownWorkingDirectory && canChangeDirectorySafely
        case #selector(openProjectRootInNewPane(_:)):
            return hasKnownWorkingDirectory
        // A failed pane (`PaneFailureView`) has nothing to clear.
        case #selector(clearScreen(_:)), #selector(clearHistory(_:)), #selector(resetTerminal(_:)):
            return host?.isOperable == true
        default:
            return true
        }
    }
}

/// The presented panel, for `onCancel` to dismiss. Main-actor isolated, so
/// `onCancel` reaches it through its hop.
@MainActor
private final class PresentedPanelBox {
    var panel: NSSavePanel?
}
