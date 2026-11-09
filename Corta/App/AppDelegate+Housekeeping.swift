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

/// What launch and quit look after besides windows: resuming the saved
/// arrangement once its file answers, a leftover export reported once, and
/// a close question a quit must not ask twice.
extension AppDelegate {
    /// What a launch whose saved arrangement could not be read does once
    /// a later read answers.
    enum LayoutPersistenceResumption: Equatable {
        /// Still unknown: ask again later.
        case retry
        /// No arrangement on disk: this launch's may be written.
        case resume
        /// An arrangement this launch did not open: set aside, as a failed
        /// restore's is, before this launch's is written in its place.
        case setAsideThenResume
    }

    static func layoutPersistenceResumption(
        after decision: SessionRestore.RestoreDecision?
    ) -> LayoutPersistenceResumption {
        switch decision {
        case nil: .retry
        case .nothingToRestore: .resume
        case .restore, .skipAfterFailure: .setAsideThenResume
        }
    }

    /// Reads attempted after a launch read nothing, before saving stays off
    /// for the rest of the run.
    static let restoreDecisionRereads = 6
    static let restoreDecisionRereadDelay: TimeInterval = 10

    /// The arrangement could not be read at launch (a mount that stopped
    /// answering, a file the read refused): saving stayed off for the whole
    /// run. It is read again, a few times, off the main thread; once its
    /// state is known saving resumes.
    func rereadRestoreDecision(store: SessionRestore, attempt: Int) {
        guard attempt <= Self.restoreDecisionRereads else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDecisionRereadDelay) { [weak self] in
            guard self != nil else { return }
            PathProbe.run { [weak self] in
                let decision = PathProbe.answer(timeout: SessionRestore.directoryCheckTimeout) {
                    try? store.readRestoreDecision()
                } ?? nil
                Task { @MainActor [weak self] in
                    self?.resumeLayoutPersistence(after: decision, store: store, attempt: attempt)
                }
            }
        }
    }

    private func resumeLayoutPersistence(
        after decision: SessionRestore.RestoreDecision?, store: SessionRestore, attempt: Int
    ) {
        guard layoutPersistenceSuspended else { return }
        switch Self.layoutPersistenceResumption(after: decision) {
        case .retry:
            rereadRestoreDecision(store: store, attempt: attempt + 1)
        case .resume:
            layoutPersistenceSuspended = false
            noteLayoutChanged()
        case .setAsideThenResume:
            layoutWrites.async { [weak self] in
                let archived = (try? store.setAsideFailedRestore()) != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if archived {
                        self.layoutPersistenceSuspended = false
                        self.noteLayoutChanged()
                    } else {
                        self.rereadRestoreDecision(store: store, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    /// Once: the record is gone after this, so the same folder is not named
    /// again.
    func reportStrandedExports(_ folders: [String]) {
        let alert = NSAlert()
        alert.messageText = L10n.text("export.stranded.title")
        alert.informativeText = L10n.format(
            "export.stranded.detail", Set(folders).sorted().joined(separator: "\n"))
        alert.present(for: terminalWindowControllers.first?.window) { _ in }
    }

    /// The first of `windows` showing a close confirmation as a sheet.
    static func windowAskingToClose(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.attachedSheet?.identifier == SplitViewController.closeConfirmationIdentifier }
    }

    /// How long a quit waits for the last writes, all of them together.
    static let quitFlushDeadline: DispatchTimeInterval = .milliseconds(1500)

    /// Every store's last write at once, under one deadline: one after
    /// another, a slow disk could spend each its own second in turn. The
    /// caller adds what it must do after the panes close, then waits.
    func beginLastWrites() -> (DispatchGroup, DispatchTime) {
        let writes = DispatchGroup()
        let deadline = DispatchTime.now() + Self.quitFlushDeadline
        pendingLayoutSave?.cancel()
        pendingLayoutSave = nil
        saveWindowStates(completion: writes)
        DirectoryHistoryStore.shared.flush(into: writes, deadline: deadline)
        RecentHostsStore.flushSharedAtQuit(into: writes, deadline: deadline)
        RemoteEditStore.flushSharedAtQuit(into: writes)
        return (writes, deadline)
    }

    /// Leftovers of earlier runs, off the main thread; a folder given up on
    /// is reported once.
    func sweepAbandonedStateFiles() {
        DispatchQueue.global(qos: .utility).async {
            let stranded = AppPaths.removeAbandonedStateFiles()
            guard !stranded.isEmpty else { return }
            Task { @MainActor [weak self] in self?.reportStrandedExports(stranded) }
        }
    }
}
