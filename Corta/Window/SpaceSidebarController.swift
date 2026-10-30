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

/// Space's sidebar: every project, and under each its sessions — two levels
/// of a compact source list on an island, like an editor's file tree.
///
/// A session's state is on its row whether or not its panel is on screen:
/// the sessions out of sight are the ones whose state needs saying. Rows
/// drag onto grid panels.
@MainActor
final class SpaceSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate
{
    weak var space: CortaSpaceController?
    let outline = SpaceOutlineView()
    private let header = SpaceSidebarHeader()
    private var isReloading = false
    /// The session whose row is being renamed; reloads wait for it.
    private weak var renaming: SpaceSession?
    /// A hidden session chosen in the list. Choosing is not showing: the
    /// grid does not change until it is asked to.
    weak var chosen: SpaceSession?
    /// The row of the last click: a double-click is two on the same row,
    /// not two quick clicks on two sessions.
    private var lastClickRow = -1
    /// What each row last showed, so a refresh redraws only rows that changed.
    private var shown: [ObjectIdentifier: SpaceSessionCell.Content] = [:]
    private var shownProjectRows: [ObjectIdentifier: String] = [:]
    private var shownProjects: [String] = []

    override func loadView() {
        configureOutline()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        header.addButton.target = self
        header.addButton.action = #selector(openProject)
        view = makePanel(holding: scroll)
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        // A session on screen is focused straight from the click
        // (`SpaceOutlineView`), so the list never takes the keyboard on the
        // way and the panel never blinks. Hidden ones are chosen here, and
        // the list keeps the keyboard for Return and ⌘Return.
        outline.sidebar = self
        // The island is the background; the list draws only its rows.
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityIdentifier("Corta.Space.Sidebar")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
    }

    /// An island, as an editor's panels are: a rounded card on the window's
    /// darker background, the same card the grid's panels are, below the
    /// titlebar and the same gap from every edge.
    private func makePanel(holding scroll: NSScrollView) -> NSView {
        let root = SpaceBackgroundView()
        let island = SpaceIslandView()
        island.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(island)
        for child in [header, scroll] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            island.addSubview(child)
        }
        let gap = SpaceGrid.dividerThickness
        NSLayoutConstraint.activate([
            island.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            island.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gap),
            island.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            island.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            header.topAnchor.constraint(equalTo: island.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: island.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: island.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: island.bottomAnchor, constant: -4),
        ])
        return root
    }

    // MARK: - Reloading

    /// A full reload when the projects or their sessions changed; otherwise
    /// only the rows whose title or state did.
    func setWaitingCount(_ count: Int) { header.setWaitingCount(count) }

    func reload() {
        guard isViewLoaded, let space, renaming == nil else { return }
        let structure = space.projects.map { project in
            project.path + ":" + project.sessions.map { $0.id.uuidString }.joined(separator: ",")
        }
        isReloading = true
        defer { isReloading = false }
        if structure != shownProjects {
            shownProjects = structure
            shown = [:]
            outline.reloadData()
            for project in space.projects { outline.expandItem(project) }
        } else {
            refreshRows(of: space)
        }
        for project in space.projects {
            shownProjectRows[ObjectIdentifier(project)] = projectRowKey(project)
            for session in project.sessions { shown[ObjectIdentifier(session)] = content(of: session) }
        }
        if let chosen,
           space.selectedProject?.shown.contains(chosen) == true || space.session(withID: chosen.id) == nil {
            self.chosen = nil
        }
        let selected: AnyObject? = chosen ?? space.focusedSession ?? space.selectedProject
        let row = selected.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 {
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            outline.deselectAll(nil)
        }
    }

    /// Rows whose content changed, updated in place: a reloaded row is torn
    /// down and drawn again, and switching projects changes several rows at
    /// once — they would all blink.
    private func refreshRows(of space: CortaSpaceController) {
        for project in space.projects {
            if shownProjectRows[ObjectIdentifier(project)] != projectRowKey(project) {
                if let cell = cell(for: project) as? SpaceProjectCell {
                    cell.configure(project, isSelected: project === space.selectedProject)
                } else {
                    outline.reloadItem(project)
                }
            }
            for session in project.sessions where shown[ObjectIdentifier(session)] != content(of: session) {
                if let cell = cell(for: session) as? SpaceSessionCell {
                    cell.configure(content(of: session))
                } else {
                    outline.reloadItem(session)
                }
            }
        }
    }

    /// The row's view, if it is on screen.
    private func cell(for item: AnyObject) -> NSView? {
        let row = outline.row(forItem: item)
        return row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) : nil
    }

    private func content(of session: SpaceSession) -> SpaceSessionCell.Content {
        let onScreen = space?.selectedProject?.shown.contains { $0 === session } == true
        return SpaceSessionCell.Content(
            presentation: SpaceSessionPresentation(session: session), isOnScreen: onScreen,
            hint: session === chosen && !onScreen ? space?.placementHint(for: session) : nil,
            // Only the project on screen has a grid to add to.
            canShow: !onScreen && space?.session(withID: session.id)?.project === space?.selectedProject)
    }

    /// What a project row shows; it reloads only when this changes.
    private func projectRowKey(_ project: SpaceProject) -> String {
        "\(project === space?.selectedProject)|\(project.attentionCount)|" +
            (project.sessions.map { session in
                let onScreen = space?.selectedProject?.shown.contains { $0 === session } == true
                return onScreen ? "1" : "0"
            }.joined())
    }

    // MARK: - Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return space?.projects.count ?? 0 }
        return (item as? SpaceProject)?.sessions.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let project = item as? SpaceProject { return project.sessions[index] }
        return space?.projects[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SpaceProject).map { !$0.sessions.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        26
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SpaceRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let project = item as? SpaceProject {
            let cell = outlineView.makeView(withIdentifier: SpaceProjectCell.identifier, owner: nil)
                as? SpaceProjectCell ?? SpaceProjectCell()
            cell.configure(project, isSelected: project === space?.selectedProject)
            return cell
        }
        guard let session = item as? SpaceSession, space != nil else { return nil }
        let cell = outlineView.makeView(withIdentifier: SpaceSessionCell.identifier, owner: nil)
            as? SpaceSessionCell ?? SpaceSessionCell()
        cell.configure(content(of: session))
        cell.showButton.target = self
        cell.showButton.action = #selector(showMenu(_:))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let session = item as? SpaceSession, session.pane != nil,
              space?.session(withID: session.id)?.project === space?.selectedProject else { return nil }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(session.id.uuidString, forType: SpacePaneView.sessionType)
        return pasteboard
    }

}

// MARK: - Choosing and renaming

extension SpaceSidebarController {
    // MARK: - Choosing

    /// A click that reached the list: a project, or a hidden session to
    /// choose. Sessions on screen never get here (`focusOnScreen`).
    @objc private func rowClicked() {
        guard !isReloading, let space else { return }
        let item = outline.item(atRow: outline.clickedRow)
        // After this action returns: selecting a project reloads this
        // outline, which must not happen inside its own mouse handling.
        DispatchQueue.main.async { [weak self] in
            if let session = item as? SpaceSession {
                self?.choose(session)
            } else if let project = item as? SpaceProject {
                space.selectProject(project)
            }
        }
    }

    /// Selects a hidden session and says what showing it would do.
    func choose(_ session: SpaceSession) {
        guard let space, let (project, _) = space.session(withID: session.id) else { return }
        if project !== space.selectedProject { space.selectProject(project) }
        if project.shown.contains(session) {
            space.focus(session)
            return
        }
        chosen = session
        reload()
    }

    /// The row's button, a double-click, ⌘Return: the chosen session goes
    /// into the grid.
    @objc func showChosen() {
        guard let session = chosen ?? (outline.item(atRow: outline.selectedRow) as? SpaceSession) else { return }
        chosen = nil
        space?.show(session)
    }

    @objc private func openProject() { space?.chooseProject() }

    /// The list's own handling, before AppKit selects: a session on screen
    /// is focused without the list taking the keyboard; a double-click on a
    /// hidden one shows it. True when handled.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        // A project: chosen without the list taking the keyboard, so the
        // terminal keeps its focus ring on the way. Its disclosure arrow is
        // still the list's.
        if row >= 0, let project = outline.item(atRow: row) as? SpaceProject, let space,
           !outline.frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: -4).contains(point) {
            if project !== space.selectedProject { space.selectProject(project) }
            return true
        }
        guard row >= 0, let session = outline.item(atRow: row) as? SpaceSession, let space,
              let (project, _) = space.session(withID: session.id) else { return false }
        // A double-click names the session, wherever it is.
        let previousRow = lastClickRow
        lastClickRow = row
        if event.clickCount >= 2, previousRow == row {
            beginRename(session)
            return true
        }
        if project === space.selectedProject, project.shown.contains(session) {
            focusOnScreen(session, row: row, event: event)
            return true
        }
        return false
    }

    /// Focuses the panel on mouse-up, or carries the row as a drag if the
    /// pointer moves first.
    private func focusOnScreen(_ session: SpaceSession, row: Int, event: NSEvent) {
        guard let window = outline.window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                chosen = nil
                space?.focus(session)
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                let item = NSPasteboardItem()
                item.setString(session.id.uuidString, forType: SpacePaneView.sessionType)
                let dragging = NSDraggingItem(pasteboardWriter: item)
                let frame = outline.rect(ofRow: row)
                let image = outline.view(atColumn: 0, row: row, makeIfNecessary: false).flatMap { cell in
                    cell.bitmapImageRepForCachingDisplay(in: cell.bounds).map { rep -> NSImage in
                        cell.cacheDisplay(in: cell.bounds, to: rep)
                        let image = NSImage(size: cell.bounds.size)
                        image.addRepresentation(rep)
                        return image
                    }
                }
                dragging.setDraggingFrame(frame, contents: image)
                outline.beginDraggingSession(with: [dragging], event: event, source: outline)
                return
            }
        }
    }

    /// Return renames, as in the Finder; ⌘Return shows the session in the
    /// grid; Escape gives the keyboard back to the grid. Only while the list
    /// has the keyboard — a terminal's Return is the program's.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76:
            guard let session = outline.item(atRow: outline.selectedRow) as? SpaceSession else { return false }
            if flags == .command {
                chosen = session
                showChosen()
            } else if flags.isEmpty {
                beginRename(session)
            } else {
                return false
            }
            return true
        case 53:
            chosen = nil
            space?.focus(space?.focusedSession ?? space?.selectedProject?.focused)
            return true
        default:
            return false
        }
    }

    // MARK: - Renaming

    /// Edits the session's name in its row. Return keeps it, Escape leaves
    /// it, an empty name goes back to the program's own.
    func beginRename(_ session: SpaceSession) {
        guard let space, space.session(withID: session.id) != nil else { return }
        if let (project, _) = space.session(withID: session.id) { outline.expandItem(project) }
        let row = outline.row(forItem: session)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SpaceSessionCell,
              let field = cell.textField else { return }
        renaming = session
        field.stringValue = session.record.name ?? SpaceSessionPresentation(session: session).title
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let session = renaming else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        field.isEditable = false
        field.delegate = nil
        renaming = nil
        if movement != NSTextMovement.cancel.rawValue {
            space?.rename(session, to: field.stringValue)
        } else {
            reload()
        }
        // The keyboard goes back to the terminal it came from.
        space?.focus(space?.focusedSession ?? space?.selectedProject?.focused)
    }
}
