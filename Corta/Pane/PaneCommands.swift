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
    let buildSelectionText: @Sendable (SelectionRange, Grid) -> String
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
    @objc func increaseFontSize(_: Any?) {
        guard let host else { return }
        applyFontSizeForAllPanes(host.fontSize + 1, isZoomed: true, settle: true)
    }

    @objc func decreaseFontSize(_: Any?) {
        guard let host else { return }
        applyFontSizeForAllPanes(host.fontSize - 1, isZoomed: true, settle: true)
    }

    /// Ends the zoom at the config file's current size, as a new window would
    /// open.
    @objc func resetFontSize(_: Any?) {
        let configured = CGFloat(ConfigurationStore.shared.configuration.fontSize)
        applyFontSizeForAllPanes(configured, isZoomed: false, settle: true)
    }

    /// Pinch zoom, spent one whole point at a time so it lands on ⌘+/⌘−'s
    /// steps: each size is an atlas rebuild. The grid follows through the
    /// drag debounce and settles once, when the pinch ends.
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

    /// The next pinch starts from zero; this one's grid settles.
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
    @objc func clearScreen(_: Any?) {
        applyTerminalState(.clearScreen, notice: "toast.clearedScreen")
    }

    @objc func clearHistory(_: Any?) {
        confirmDiscardingHistory(titleKey: "clear.history.title") { [weak self] in
            self?.applyTerminalState(.clearHistory, notice: "toast.clearedHistory")
        }
    }

    @objc func resetTerminal(_: Any?) {
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
        host.pointer.clearSelection()
        host.scrollOffset = 0
        host.invalidateDisplay()
        host.terminalView?.noteAccessibilityValueChanged()
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
final class PresentedPanelBox {
    var panel: NSSavePanel?
}
