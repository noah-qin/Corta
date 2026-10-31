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

extension CortaSpaceController {
    func promptWorktree(from session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.worktree.prompt")
        alert.informativeText = L10n.text("space.worktree.detail")
        let name = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        name.stringValue = gitFacts[session.id]?.detached == false ? (gitFacts[session.id]?.name ?? "topic") : "topic"
        let branch = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        branch.placeholderString = L10n.text("space.worktree.branchOptional")
        let preview = WorktreeLocationPreview(project: project.path, name: name)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 84))
        preview.label.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        stack.addSubview(preview.label)
        name.frame = NSRect(x: 0, y: 56, width: 280, height: 24)
        branch.frame = NSRect(x: 0, y: 28, width: 280, height: 24)
        stack.addSubview(name)
        stack.addSubview(branch)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("space.worktree.new"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            preview.update()
            let newBranch = !branch.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let branchName = newBranch ? branch.stringValue : name.stringValue
            guard let location = WorktreeCommand.location(projectPath: project.path, name: name.stringValue),
                  let command = WorktreeCommand.line(location: location, branch: branchName, newBranch: newBranch)
            else {
                self.content.showNote(L10n.text("space.worktree.rejected"))
                return
            }
            self.newSession(directory: project.path)
            self.fillWhenReady(command: command, note: "space.worktree.filled")
        }
    }

    func revealWorktreeMain(_ session: SpaceSession) {
        guard let path = gitFacts[session.id]?.mainRepository else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func fillWhenReady(command: String, note: String, session requested: SpaceSession? = nil) {
        guard let session = requested ?? focusedSession else { return }
        Task { @MainActor [weak self, weak session] in
            let deadline = SuspendingClock.now.advanced(by: .seconds(10))
            while SuspendingClock.now < deadline {
                if session?.pane?.shell.fillPrompt(with: command) == true {
                    self?.content.showNote(L10n.text(note))
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

}

private final class WorktreeLocationPreview: NSObject, NSTextFieldDelegate {
    let label = NSTextField(labelWithString: "")
    let project: String
    let name: NSTextField
    init(project: String, name: NSTextField) {
        self.project = project
        self.name = name
        super.init()
        name.delegate = self
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        update()
    }
    func controlTextDidChange(_ notification: Notification) { update() }
    func update() {
        label.stringValue = WorktreeCommand.location(projectPath: project, name: name.stringValue)
            ?? L10n.text("space.worktree.rejected")
        label.toolTip = label.stringValue
    }
}
