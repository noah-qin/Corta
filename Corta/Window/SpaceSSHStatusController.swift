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

/// What the SSH status button opens: the status, what it means, the exact
/// tmux name with a copy button, and the separately confirmed way to end it.
final class SpaceSSHStatusController: NSViewController {
    private let status: SpaceSSHStatus
    private let killCommand: String
    private let canEnd: Bool
    private let onEnd: () -> Void

    init(status: SpaceSSHStatus, killCommand: String, canEnd: Bool, onEnd: @escaping () -> Void) {
        self.status = status
        self.killCommand = killCommand
        self.canEnd = canEnd
        self.onEnd = onEnd
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let heading = NSTextField(labelWithAttributedString: SpacePaneView.statusTitle(status))
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let icon = NSImageView(image: SpacePaneView.statusImage(status) ?? NSImage())
        let top = NSStackView(views: [icon, heading])
        top.spacing = 6
        var rows: [NSView] = [top, Self.paragraph(status.detail)]
        if status.isInTmux {
            rows.append(Self.paragraph(L10n.text("space.ssh.note"), secondary: true))
            rows.append(Self.paragraph(L10n.text("space.ssh.history"), secondary: true))
        }
        let name = NSTextField(labelWithString: killCommand)
        name.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        name.textColor = .secondaryLabelColor
        name.isSelectable = true
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc",
            accessibilityDescription: L10n.text("common.copy")) ?? NSImage(), target: self, action: #selector(copyName))
        copy.bezelStyle = .glass
        copy.controlSize = .small
        copy.toolTip = L10n.text("common.copy")
        rows.append(NSStackView(views: [name, copy]))
        if canEnd {
            let end = NSButton(title: L10n.text("space.ssh.kill.title"), target: self, action: #selector(end))
            end.bezelStyle = .glass
            end.controlSize = .small
            rows.append(end)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.setAccessibilityIdentifier("Corta.Space.SSHStatusDetails")
        view = stack
    }

    private static func paragraph(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 340
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }

    @objc private func copyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(killCommand, forType: .string)
    }

    @objc private func end() { onEnd() }
}
