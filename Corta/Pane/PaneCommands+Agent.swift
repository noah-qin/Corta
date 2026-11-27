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

enum AgentPaneTargets {
    static func candidates(
        in window: TerminalWindowController, excluding source: TerminalPaneViewController,
        configured: String, read: @MainActor (TerminalPaneViewController) -> ForegroundProgram? = readProgram
    ) -> [TerminalPaneViewController] {
        window.tabs.flatMap { $0.split.panes }.filter { pane in
            pane !== source && isEligible(read(pane), configured: configured)
        }
    }

    static func resolve(
        _ id: UUID, sessionID: UUID, in window: TerminalWindowController, configured: String,
        read: @MainActor (TerminalPaneViewController) -> ForegroundProgram? = readProgram
    ) -> TerminalPaneViewController? {
        guard let pane = window.tabs.lazy.flatMap({ $0.split.panes }).first(where: {
            $0.taskNotifier.paneID == id
        }), pane.session?.id == sessionID, isEligible(read(pane), configured: configured)
        else { return nil }
        return pane
    }

    private static func readProgram(_ pane: TerminalPaneViewController) -> ForegroundProgram? {
        guard !pane.didTeardown, pane.isOperable, let session = pane.session, !session.isStopped else {
            return nil
        }
        return session.foregroundProgram
    }

    private static func isEligible(_ program: ForegroundProgram?, configured: String) -> Bool {
        guard let program, !program.members.contains(where: {
            PaneRemoteState.isRemoteLauncher(executable: $0.name)
        }) else { return false }
        return PaneAgents.isAgent(program, configured: configured)
    }
}

extension PaneCommands {
    @objc func sendSelectionToAgent(_: Any?) {
        guard let host, host.isOperable, let session = host.session, host.selection != nil else { return }
        let grid = session.snapshot()
        host.pointer.dropSelectionIfRewritten(in: grid)
        guard let selection = host.selection else { return }
        let range = host.pointer.selectionRange(for: selection, in: grid)
        let hostName: String?
        let directory: String?
        switch host.remote.state {
        case .local:
            hostName = ProcessInfo.processInfo.hostName
            directory = session.currentDirectory
        case .remote(let name, let path, _):
            (hostName, directory) = (name, path)
        case .connected(let target, let path):
            (hostName, directory) = (target, path)
        case .remoteUnknown, .unknown:
            (hostName, directory) = (nil, nil)
        }
        sendToAgent(grid: grid, range: range, hostName: hostName, directory: directory)
    }

    @objc func sendCommandOutputToAgent(_: Any?) {
        sendCommandOutputToAgent(for: host?.effectiveCommand)
    }

    func sendCommandOutputToAgent(for record: CommandRecord?) {
        guard let host, host.isOperable, let session = host.session else { return }
        let grid = session.snapshot()
        guard let record, !grid.isAlternateScreenActive,
            let range = PaneShellIntegration.commandOutputRange(grid: grid, record: record)
        else {
            showMissingCommandOutput()
            return
        }
        sendToAgent(
            grid: grid, range: range, hostName: record.host,
            directory: record.host == nil ? record.workingDirectory : nil, record: record)
    }

    private func showMissingCommandOutput() {
        let integrated = host?.session?.hasShellIntegration == true
        host?.terminalView?.showToast(
            L10n.text(integrated ? "toast.noCommandOutput" : "toast.noShellIntegration"), kind: .warning)
    }

    private func sendToAgent(
        grid: Grid, range: SelectionRange, hostName: String?, directory: String?, record: CommandRecord? = nil
    ) {
        guard let source = host as? TerminalPaneViewController, let sourceSession = source.session?.id,
            let window = source.splitController?.tab?.controller
        else { return }
        let configured = ConfigurationStore.shared.configuration.agentProcesses
        let candidates = AgentPaneTargets.candidates(in: window, excluding: source, configured: configured)
        guard !candidates.isEmpty else {
            source.terminalView?.showToast(L10n.text("toast.noAgentPane"), kind: .warning)
            return
        }

        let targets = candidates.map {
            CommandPaletteModel.AgentPaneTarget(
                id: $0.taskNotifier.paneID, title: $0.windowTitle.notificationTitle)
        }
        let sessions = Dictionary(uniqueKeysWithValues: candidates.compactMap { pane in
            pane.session.map { (pane.taskNotifier.paneID, $0.id) }
        })
        let paneName = source.windowTitle.notificationTitle
        let buildText = buildSelectionText
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self, weak window] in
            let payload = AgentPanePayload.make(
                text: buildText(range, grid), paneName: paneName, host: hostName, directory: directory,
                command: PaneShellIntegration.commandLineText(grid: grid, record: record),
                exitStatus: record?.exitStatus)
            await MainActor.run {
                guard let self, self.largeTextTaskGeneration == generation else { return }
                self.largeTextTask = nil
                guard !Task.isCancelled, let window, let hostWindow = window.window,
                    self.hasAgentSource(in: window, sessionID: sourceSession, generation: generation)
                else { return }
                guard let payload else {
                    if record != nil { self.showMissingCommandOutput() }
                    return
                }
                let deliver: (UUID) -> Void = { [weak self, weak window] id in
                    guard let self, let window,
                        self.hasAgentSource(in: window, sessionID: sourceSession, generation: generation)
                    else { return }
                    self.deliver(payload, to: id, sessionID: sessions[id], in: window)
                }
                if targets.count == 1 {
                    deliver(targets[0].id)
                } else {
                    CommandPaletteController.shared.pickAgentPane(targets, in: hostWindow, onPick: deliver)
                }
            }
        }
    }

    private func hasAgentSource(in window: TerminalWindowController, sessionID: UUID, generation: Int) -> Bool {
        guard let source = host as? TerminalPaneViewController else { return false }
        return largeTextTaskGeneration == generation && !source.didTeardown && source.session?.id == sessionID
            && source.splitController?.tab?.controller === window
    }

    private func deliver(
        _ payload: AgentPanePayload, to id: UUID, sessionID: UUID?, in window: TerminalWindowController
    ) {
        let configured = ConfigurationStore.shared.configuration.agentProcesses
        guard let sessionID,
            let target = AgentPaneTargets.resolve(id, sessionID: sessionID, in: window, configured: configured)
        else {
            host?.terminalView?.showToast(L10n.text("toast.agentPaneUnavailable"), kind: .warning)
            return
        }
        AgentDirectory.focus(target)
        target.composer.offer(payload.text)
        target.terminalView?.showToast(
            L10n.format("toast.agentPaneAdded", payload.text.utf8.count, payload.sourceName))
    }
}
