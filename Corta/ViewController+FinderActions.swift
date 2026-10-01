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

import Cocoa
import CortaTerminal

/// Finder and working-directory actions. No outbound drag: it would need a
/// new drag gesture beside selection dragging; Reveal and Copy Path cover
/// the need with existing APIs.
extension ViewController {
    /// `session.workingDirectory` is nil when remote or unreported
    /// (`Performer+OSC.swift`).
    var hasKnownWorkingDirectory: Bool {
        isOperable && session.workingDirectory != nil
    }

    @objc func revealWorkingDirectoryInFinder(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// Copies the path, confirmed by toast.
    @objc func copyWorkingDirectoryPath(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            terminalView?.showToast(L10n.text("toast.noWorkingDirectory"), kind: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(directory, forType: .string)
        terminalView?.showToast(L10n.text("toast.copiedWorkingDirectory"))
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
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        withProjectRoot(of: directory) { controller, root in
            controller.changeDirectory(to: root)
        }
    }

    /// Splits with a new pane rooted at the parent directory.
    @objc func openParentDirectoryInNewPane(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        splitController?.splitFocusedPane(orientation: .columns, workingDirectory: parent)
    }

    @objc func openProjectRootInNewPane(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        withProjectRoot(of: directory) { controller, root in
            controller.splitController?.splitFocusedPane(orientation: .columns, workingDirectory: root)
        }
    }

    /// Finds `directory`'s project root off the main thread — the walk
    /// `stat`s a child-reported path, which can sit on an unreachable
    /// automount — then runs `body` on it, or reports that there is none.
    private func withProjectRoot(
        of directory: String, _ body: @escaping @MainActor (ViewController, String) -> Void
    ) {
        Task { [weak self] in
            let root = await Task.detached(priority: .userInitiated) {
                DirectoryHistory.projectRoot(for: directory)
            }.value
            // The lookup can outlast a change of focus; the toast or split
            // would then land on another pane.
            guard let self, !didTeardown, isFocusedPane else { return }
            guard let root else {
                terminalView?.showToast(L10n.text("toast.noProjectRoot"), kind: .warning)
                return
            }
            body(self, root)
        }
    }
}
