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

/// The sidebar's menus: a row's context menu, and the add button's.
extension SpaceSidebarController {
    /// The row's add button: where the session would go, said first; or
    /// in the place of any panel on screen.
    @objc func showMenu(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let session = outline.item(atRow: row) as? SpaceSession, let space,
              let (project, _) = space.session(withID: session.id) else { return }
        let menu = NSMenu()
        let automatic = menu.addItem(
            withTitle: L10n.text("space.panel.show") + " — " + space.placementHint(for: session),
            action: #selector(runMenuAction(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = SpaceMenuAction { [weak self] in
            self?.chosen = session
            self?.showChosen()
        }
        let targets = project === space.selectedProject ? project.shown : []
        if !targets.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: L10n.text("space.panel.replaceHeader")))
            for target in targets {
                let entry = menu.addItem(
                    withTitle: SpaceSessionPresentation(session: target).title,
                    action: #selector(runMenuAction(_:)), keyEquivalent: "")
                entry.target = self
                entry.image = NSImage(
                    systemSymbolName: SpaceSessionPresentation(session: target).symbol, accessibilityDescription: nil)
                entry.representedObject = SpaceMenuAction { space.show(session, in: target) }
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? SpaceMenuAction)?.run()
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let space else { return }
        let item = outline.item(atRow: outline.clickedRow)
        if let session = item as? SpaceSession, let (project, _) = space.session(withID: session.id) {
            addSessionItems(to: menu, session: session, project: project, space: space)
        } else if let project = item as? SpaceProject {
            addProjectItems(to: menu, project: project, space: space)
        } else {
            add("space.openProject", to: menu) { space.chooseProject() }
        }
    }

    @discardableResult
    private func add(_ key: String, to menu: NSMenu, _ action: @escaping () -> Void) -> NSMenuItem {
        let entry = menu.addItem(withTitle: L10n.text(key), action: #selector(runMenuAction(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = SpaceMenuAction(action)
        return entry
    }

    private func addSessionItems(
        to menu: NSMenu, session: SpaceSession, project: SpaceProject, space: CortaSpaceController
    ) {
        let onScreen = project === space.selectedProject && project.shown.contains { $0 === session }
        if onScreen {
            add("space.panel.hide", to: menu) { space.hide(session) }
            add(project.maximized === session ? "space.panel.restore" : "space.panel.maximize", to: menu) {
                space.toggleMaximize(session)
            }
        } else {
            add("space.panel.show", to: menu) { [weak self] in
                self?.chosen = session
                self?.showChosen()
            }
            // A chosen destination over the automatic one.
            let targets = project === space.selectedProject ? project.shown : []
            if !targets.isEmpty {
                let submenu = NSMenu()
                for target in targets {
                    add(SpaceSessionPresentation(session: target).title, to: submenu, literal: true) {
                        space.show(session, in: target)
                    }
                }
                menu.addItem(withTitle: L10n.text("space.panel.showIn"), action: nil, keyEquivalent: "")
                    .submenu = submenu
            }
        }
        add("space.session.rename", to: menu) { [weak self] in self?.beginRename(session) }
        if session.record.ssh == nil {
            if space.gitFacts[session.id]?.worktree == true {
                add("space.worktree.reveal", to: menu) { space.revealWorktreeMain(session) }
            }
        }
        if space.canBrowseFiles(of: session) {
            add("space.session.browseFiles", to: menu) { space.browseFiles(of: session) }
        }
        // Recovery details, for when it went wrong: off the first level.
        if let conversation = session.record.conversation, session.record.ssh == nil {
            let diagnostics = NSMenu()
            diagnostics.autoenablesItems = false
            diagnostics.addItem(NSMenuItem.sectionHeader(title: L10n.format(
                "space.conversation.source", conversation.source.rawValue)))
            let refill = add("space.conversation.fillAgain", to: diagnostics) { space.refillConversation(session) }
            refill.isEnabled = space.canFillConversation(session)
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.text("space.session.diagnostics"), action: nil, keyEquivalent: "")
                .submenu = diagnostics
        }
        menu.addItem(.separator())
        if session.record.retainSSH == true {
            add("space.ssh.kill.title", to: menu) { space.endRemoteSession(session) }
        }
        add("space.session.end", to: menu) { space.endSession(session) }
    }

    private func addProjectItems(to menu: NSMenu, project: SpaceProject, space: CortaSpaceController) {
        add("space.newSession", to: menu) { space.selectProject(project); space.newSession() }
        if let session = project.sessions.first(where: { space.gitFacts[$0.id]?.mainRepository != nil }) {
            add("space.worktree.reveal", to: menu) { space.revealWorktreeMain(session) }
        }
        add("space.connectSSH", to: menu) { space.selectProject(project); space.connectSession() }
        let hosts = space.remoteHosts(of: project)
        if !hosts.isEmpty {
            let submenu = NSMenu()
            for target in hosts {
                let entry = add(target.displayName, to: submenu, literal: true) {
                    space.browseFiles(on: target, for: project)
                }
                entry.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            }
            menu.addItem(withTitle: L10n.text("space.project.remoteFiles"), action: nil, keyEquivalent: "")
                .submenu = submenu
        }
        menu.addItem(.separator())
        add("space.project.reveal", to: menu) { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
        menu.addItem(.separator())
        add("space.project.remove", to: menu) { space.removeProject(project) }
    }

    /// An item titled as given — a session's or host's name, not a key.
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, literal: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = SpaceMenuAction(action)
        return entry
    }
}
