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

/// Space: project folders, each with its own sessions, shown up to four at a
/// time in a grid beside a sidebar that lists every one of them.
///
/// The two modes are two sets of sessions in one window. The terminal mode
/// keeps its split tree whole while Space shows, and Space keeps its sessions
/// running while the terminal mode shows; switching changes what is on screen,
/// never the window's frame or a process. Every pane stays a child of the
/// window's `SplitViewController`, which still routes focus, input and close.
///
/// There is one Space in the app: the window that first shows it owns its
/// sessions, and asking for Space anywhere else brings that window forward.
/// What it remembers across launches is `SpaceStore`'s, in Application
/// Support; a project folder is never written to.
@MainActor
final class CortaSpaceController: NSObject {
    /// The window whose Space holds the live sessions.
    private(set) static weak var owner: CortaSpaceController?

    weak var host: SplitViewController?
    /// Transport construction is injectable for isolated SSH tests, never configuration.
    var makeSSHPreset: (SSHTarget, RemoteTmux?) -> Preset = { SSHDestination.preset(for: $0, retaining: $1) }
    /// Alert presentation is injectable so a test never runs an app-modal dialog.
    var presentAlert: (
        NSAlert, NSWindow?, @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void = { alert, window, done in
        alert.present(for: window, completion: done)
    }
    private(set) var isActive = false
    private(set) var projects: [SpaceProject] = []
    private(set) var selectedProject: SpaceProject?
    private var isLoaded = false
    var usageClock: UInt64 = 0
    private weak var terminalFocus: ViewController?
    var conversationMonitor: Task<Void, Never>?
    var attentionQueue = AttentionQueue()
    var gitFacts: [UUID: GitFacts] = [:]
    var launchRemoteTermination: ((SSHTarget, String) -> Void)?
    let gitMonitor = GitStatusMonitor()
    private var pendingSave: DispatchWorkItem?
    var isRefreshScheduled = false
    var isOutputRefreshScheduled = false
    private var observers: [NSObjectProtocol] = []

    let splitController = SpaceSplitController()
    let sidebar = SpaceSidebarController()
    let content = SpaceContentController()
    var panels: [ObjectIdentifier: SpacePaneView] = [:]
    var isRebuildingGrid = false
    /// Whether the one-time note on what ends with the window has been shown.
    /// Kept in `space.json`, app state like the rest (D10: not `UserDefaults`).
    private(set) var isIntroductionShown = false
    /// Off in tests, which read the layout right after switching.
    static var animatesModeChanges = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    /// Off in tests unless one asks for it: a sheet would hold every later
    /// test's window.
    static var showsIntroduction = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    init(host: SplitViewController) {
        self.host = host
        super.init()
        sidebar.space = self
        content.space = self
        gitMonitor.onUpdate = { [weak self] facts in
            guard let self, self.gitFacts != facts else { return }
            self.gitFacts = facts
            self.sidebar.reload()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AgentDirectory.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: ConfigurationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        })
    }

    /// `space-panel-limit`, within the grid's four.
    var panelLimit: Int {
        min(SpaceGrid.maximumPanels, max(1, ConfigurationStore.shared.configuration.spacePanelLimit))
    }

    // MARK: - Mode

    /// Shows Space or the terminal mode in this window. Another window's
    /// Space is brought forward rather than started twice.
    func setActive(_ active: Bool) {
        defer { host?.updateToolbarForMode() }
        guard active != isActive, let host, let window = host.toolbarWindow, !(window is NSPanel) else { return }
        if active, let owner = Self.owner, owner !== self, let ownerWindow = owner.host?.toolbarWindow {
            owner.setActive(true)
            ownerWindow.tabGroup?.selectedWindow = ownerWindow
            ownerWindow.makeKeyAndOrderFront(nil)
            return
        }
        if active { enter(host: host, window: window) } else { leave(host: host, window: window) }
        host.updateToolbarForMode()
        (window.windowController as? TerminalWindowController)?.applyCanvasAppearance()
        host.updateWindowMinSize()
        host.updateDirectPresentation()
        host.noteLayoutChanged()
    }

    private func enter(host: SplitViewController, window: NSWindow) {
        Self.owner = self
        loadIfNeeded()
        host.unzoomPane()
        terminalFocus = host.focusedPane
        isActive = true
        crossfade(host.view)
        // The terminal tree leaves the window whole and comes back whole.
        // The window keeps its frame: the grid is laid out in the room the
        // window already has, and a panel that does not fit stays off screen.
        host.terminalTree.root.removeFromSuperview()
        installSplit(in: host)
        host.view.layoutSubtreeIfNeeded()
        if let project = selectedProject ?? projects.first {
            selectedProject = nil
            selectProject(project)
        } else {
            host.focusedPane = nil
            rebuildGrid()
            applyWindowTitle()
        }
        refreshNow()
        showIntroductionIfNeeded(in: window)
    }

    /// Once, the first time Space shows: what ends with the window, and what
    /// comes back. Never again after it has been dismissed.
    private func showIntroductionIfNeeded(in window: NSWindow) {
        guard Self.showsIntroduction, !isIntroductionShown else { return }
        isIntroductionShown = true
        saveNow()
        let alert = NSAlert()
        alert.messageText = L10n.text("space.introduction.title")
        alert.informativeText = L10n.text("space.introduction.detail")
        alert.addButton(withTitle: L10n.text("space.introduction.dismiss"))
        presentAlert(alert, window) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.focus(self.focusedSession)
        }
    }

    private func leave(host: SplitViewController, window: NSWindow) {
        saveNow()
        isActive = false
        attentionQueue = AttentionQueue()
        sidebar.setWaitingCount(0)
        AgentDirectory.noteSpaceWaiting(count: 0, active: false, windowIsKey: true)
        crossfade(host.view)
        splitController.view.removeFromSuperview()
        host.focusedPane = terminalFocus.flatMap { host.panes.contains($0) ? $0 : nil }
            ?? host.terminalTree.leaves.lazy.compactMap(host.pane(forLeaf:)).first
        host.installRoot()
        host.view.layoutSubtreeIfNeeded()
        for pane in host.terminalTree.leaves.compactMap(host.pane(forLeaf:)) {
            pane.resizeSessionToFitView()
            pane.invalidateDisplay()
        }
        if let pane = host.focusedPane { window.makeFirstResponder(pane.terminalView) }
        for pane in host.panes { pane.focus.applyAppearance() }
        host.applyWindowTitle()
    }

    private func installSplit(in host: SplitViewController) {
        if splitController.splitViewItems.isEmpty {
            // A plain item: the sidebar draws its own floating glass card,
            // and a sidebar item would put the system's material under it.
            let sidebarItem = NSSplitViewItem(viewController: sidebar)
            sidebarItem.minimumThickness = 200
            sidebarItem.maximumThickness = 320
            sidebarItem.canCollapse = true
            sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
            splitController.addSplitViewItem(sidebarItem)
            let contentItem = NSSplitViewItem(viewController: content)
            contentItem.minimumThickness = 320
            splitController.addSplitViewItem(contentItem)
        }
        if splitController.parent !== host { host.addChild(splitController) }
        let view = splitController.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.statusBarTopAnchor),
        ])
    }

    // MARK: - Projects

    /// Asks for a folder; from the terminal mode, shows Space first.
    func chooseProject() {
        if !isActive { setActive(true) }
        if let owner = Self.owner, owner !== self { owner.chooseProject(); return }
        guard let window = host?.toolbarWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("space.openProject.prompt")
        panel.message = L10n.text("space.openProject.message")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.openProject(url)
            }
        }
    }

    /// Adds the folder if it is new, and shows it. Choosing a folder only
    /// names where new sessions start: nothing in it is read or run.
    func openProject(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = projects.first(where: { $0.path == path }) {
            existing.isAvailable = true
            selectProject(existing)
            return
        }
        let project = SpaceProject(record: SpaceProjectRecord(path: path))
        projects.append(project)
        selectProject(project)
        if project.sessions.isEmpty { newSession() }
        scheduleSave()
    }

    func selectProject(_ project: SpaceProject) {
        guard projects.contains(where: { $0 === project }) else { return }
        if project !== selectedProject {
            selectedProject = project
            scheduleSave()
        }
        start(project)
        rebuildGrid()
        focus(project.focused.flatMap { project.shown.contains($0) ? $0 : nil } ?? project.shown.first)
        applyWindowTitle()
        refreshNow()
    }

    /// Ends the project's sessions — asking first if any is busy — and
    /// forgets it.
    func removeProject(_ project: SpaceProject) {
        guard host != nil else { return }
        if project.sessions.contains(where: { $0.record.retainSSH == true }) {
            confirmRetainedRemoval(project.sessions) { [weak self, weak project] in
                guard let project else { return }
                self?.removeProjectAfterRetentionWarning(project)
            }
        } else {
            removeProjectAfterRetentionWarning(project)
        }
    }

    private func removeProjectAfterRetentionWarning(_ project: SpaceProject) {
        guard let host else { return }
        let running = project.sessions.filter { $0.record.retainSSH != true }.compactMap(\.pane)
            .filter { $0.session?.hasForegroundJob == true }
        let scope = L10n.text("close.scope.project")
        host.confirmClose(of: running, scope: scope, in: host.toolbarWindow) { [weak self, weak project] confirmed in
            guard confirmed, let self, let project else { return }
            project.conversationPreparation?.cancel()
            for session in project.sessions { self.discard(session) }
            self.projects.removeAll { $0 === project }
            if self.selectedProject === project {
                self.selectedProject = nil
                if let next = self.projects.first {
                    self.selectProject(next)
                } else {
                    host.focusedPane = nil
                    self.rebuildGrid()
                    self.applyWindowTitle()
                }
            }
            self.refreshNow()
            self.scheduleSave()
        }
    }

}

extension CortaSpaceController {
    /// Starts every session the project remembers, each at the size it will
    /// show at: its panel's, or the whole grid's for one off screen.
    func start(_ project: SpaceProject) {
        guard !project.isStarted, project.isAvailable else { return }
        project.isStarted = true
        startConversationMonitor()
        let area = gridArea
        let sizes = project.pendingLayout?.panelSizes(in: area) ?? [:]
        for (index, session) in project.sessions.enumerated() where session.pane == nil {
            spawn(session, in: project, panelSize: sizes[index] ?? area)
        }
        prepareConversations(in: project)
    }

    /// The window is closing: written while the shells can still say where
    /// they are.
    func stop() {
        conversationMonitor?.cancel()
        conversationMonitor = nil
        for project in projects { project.conversationPreparation?.cancel() }
        saveNow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if Self.owner === self { Self.owner = nil }
    }
}

// MARK: - Fading the mode change, and saving

extension CortaSpaceController {
    /// One mode's content fades into the other's instead of cutting.
    private func crossfade(_ view: NSView) {
        guard Self.animatesModeChanges else { return }
        view.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        view.layer?.add(fade, forKey: "corta.space.mode")
    }

    // MARK: - Saving

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let state = SpaceStore.standard.load()
        projects = state.projects.map(SpaceProject.init)
        selectedProject = projects.first { $0.path == state.selectedProject } ?? projects.first
        isIntroductionShown = state.introductionShown == true
    }

    var state: SpaceState {
        var state = SpaceState(projects: projects.map(\.record), selectedProject: selectedProject?.path)
        state.introductionShown = isIntroductionShown ? true : nil
        return state
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isLoaded, Self.owner === self else { return }
        SpaceStore.standard.save(state)
    }
}
