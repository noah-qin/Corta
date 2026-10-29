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

/// Which session is in use, and keeping the chrome that shows it current.
extension CortaSpaceController {
    // MARK: - Focus and use

    /// Most recent use; the grid replaces the lowest.
    func touch(_ session: SpaceSession) {
        usageClock += 1
        session.lastUsed = usageClock
    }

    func focus(_ session: SpaceSession?) {
        guard let host else { return }
        guard let session, let pane = session.pane, pane.view.window != nil else {
            if session == nil || session?.pane == nil { host.focusedPane = nil }
            refreshNow()
            return
        }
        host.focusedPane = pane
        selectedProject?.focused = session
        touch(session)
        host.toolbarWindow?.makeFirstResponder(pane.terminalView)
        for other in host.panes { other.focus.applyAppearance() }
        scheduleRefresh()
    }

    /// Focus moved between panes. Both count as used: the one left behind
    /// was in use until now.
    func noteFocus(_ pane: ViewController, previous: ViewController?) {
        guard isActive, !isRebuildingGrid else { return }
        if let previous, let (_, session) = session(for: previous) { touch(session) }
        guard let (project, session) = session(for: pane) else { return }
        touch(session)
        project.focused = session
        scheduleRefresh()
    }

    /// A batch of output: titles in the sidebar may have changed. At most two
    /// refreshes a second, whatever the output rate.
    func noteOutput() {
        guard isActive, !isOutputRefreshScheduled else { return }
        isOutputRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isOutputRefreshScheduled = false
            self.refreshNow()
        }
    }

    // MARK: - Chrome

    func scheduleRefresh() {
        guard isActive, !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshScheduled = false
            self.refreshNow()
        }
    }

    func refreshNow() {
        guard isActive else { return }
        sidebar.reload()
        for panel in panels.values where panel.window != nil { panel.update() }
        content.update()
    }

    /// The project names the window, with its folder as the proxy icon.
    func applyWindowTitle() {
        guard isActive, let window = host?.toolbarWindow else { return }
        let title = selectedProject?.name ?? L10n.text("space.title")
        if window.title != title { window.title = title }
        if window.representedURL != selectedProject?.url { window.representedURL = selectedProject?.url }
        (window.windowController as? TerminalWindowController)?.refreshTabTitle()
    }

    func configurationChanged() {
        guard isActive else { return }
        // A lower `space-panel-limit` takes the least recently used panels
        // off screen; their sessions keep running.
        if let project = selectedProject {
            while project.shown.count > panelLimit,
                  let oldest = SpaceGrid.leastRecentlyUsed(
                      project.shown, recency: { $0.lastUsed }, protected: focusedSession) {
                hide(oldest)
            }
        }
        scheduleRefresh()
    }
}
