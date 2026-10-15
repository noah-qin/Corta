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
import CortaSFTP
import SwiftUI

// MARK: - Path bar

/// The current directory as a breadcrumb: each component goes there on a
/// click. Clicking the bar's free space — or Go to Folder… (⇧⌘G) — turns it
/// into a field for typing a path; Return goes, Escape puts the crumbs back.
/// A deep path folds its middle into "…" rather than overflowing.
struct SFTPPathBar: View {
    @Bindable var model: SFTPBrowserModel
    @Binding var editing: Bool

    nonisolated struct Crumb: Identifiable {
        let title: String
        let path: String
        var id: String { path }
    }

    private var crumbs: [Crumb] {
        Self.breadcrumbs(for: model.currentPath)
    }

    /// Build only the visible ancestors. Retaining every prefix of a peer
    /// path before folding made a frame-sized path consume quadratic memory.
    /// At most root, ellipsis and six trailing components are retained.
    nonisolated static func breadcrumbs(for path: String, keepingLast count: Int = 6) -> [Crumb] {
        let components = path.split(separator: "/")
        let kept = min(6, max(1, count))
        var result = [Crumb(title: "/", path: "/")]
        if components.count > kept + 1 {
            let ancestor = components[components.count - kept - 1]
            result.append(Crumb(title: "…", path: String(path[..<ancestor.endIndex])))
            for component in components.suffix(kept) {
                result.append(Crumb(title: String(component), path: String(path[..<component.endIndex])))
            }
        } else {
            for component in components {
                result.append(Crumb(title: String(component), path: String(path[..<component.endIndex])))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if editing {
                PathEntryField(
                    text: $model.pathField,
                    onSubmit: {
                        model.navigate(to: model.pathField)
                        editing = false
                    },
                    onCancel: stopEditing)
                .onAppear { model.pathField = model.currentPath }
            } else {
                ViewThatFits(in: .horizontal) {
                    trail(crumbs)
                    trail(folded(keepingLast: 2))
                    trail(folded(keepingLast: 1))
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 340, minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("sftp.path.label"))
    }

    private func stopEditing() {
        editing = false
        model.pathField = model.currentPath
    }

    /// Root, an ellipsis standing for the middle, and the last few.
    private func folded(keepingLast count: Int) -> [Crumb] {
        Self.breadcrumbs(for: model.currentPath, keepingLast: count)
    }

    private func trail(_ items: [Crumb]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, crumb in
                if index > 1 || (index == 1 && items[0].path != "/") {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                let isLast = index == items.count - 1
                Button(crumb.title) { model.navigate(to: crumb.path) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .disabled(isLast)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The path bar's field. AppKit, because focus asked for through SwiftUI
/// did not reach a field inside a toolbar item: this one takes first
/// responder as it joins the window, goes on Return, and gives up on
/// Escape or on losing focus.
private struct PathEntryField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "/"
        field.setAccessibilityLabel(L10n.text("sftp.path.label"))
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathEntryField
        private var finished = false
        init(_ parent: PathEntryField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finished = true
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }
    }

    private final class FocusingTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}
