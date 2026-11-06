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
import SwiftUI

/// Captures events only while its own popover is key; no global monitor.
struct ShortcutRecorder: View {
    let value: Shortcut?
    let onChange: (Shortcut?) -> Void
    @State private var recording = false

    var body: some View {
        // One column: every key cap is at least as wide as the widest
        // common chord, and the clear button keeps its slot when there is
        // nothing to clear, so caps of different lengths share a right edge.
        HStack(spacing: 8) {
            Button {
                recording = true
            } label: {
                Text(value?.displayText ?? L10n.text("ui.shortcut.record"))
                    .frame(minWidth: 52)
            }
            .help(L10n.text("ui.shortcut.recordHelp"))
            .popover(isPresented: $recording) {
                VStack(spacing: 12) {
                    Text(L10n.text("ui.shortcut.press")).font(.headline)
                    Text(L10n.text("ui.shortcut.escape")).font(.caption).foregroundStyle(.secondary)
                    ShortcutCapture { shortcut in
                        recording = false
                        if let shortcut { onChange(shortcut) }
                    }.frame(width: 220, height: 40)
                }.padding(20)
            }
            Button { onChange(nil) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help(L10n.text("ui.shortcut.clear"))
                .accessibilityLabel(L10n.text("ui.shortcut.clear"))
                .opacity(value == nil ? 0 : 1)
                .disabled(value == nil)
                .accessibilityHidden(value == nil)
        }
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let completion: (Shortcut?) -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView(completion: completion) }
    func updateNSView(_ view: CaptureView, context: Context) { view.completion = completion }

    final class CaptureView: NSView {
        var completion: (Shortcut?) -> Void
        private var completed = false
        init(completion: @escaping (Shortcut?) -> Void) {
            self.completion = completion
            super.init(frame: .zero)
            setAccessibilityLabel(L10n.text("ui.shortcut.press"))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                window?.makeFirstResponder(self)
            }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard !completed else { return }
            if event.keyCode == 53 { completed = true; completion(nil); return }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !modifiers.isEmpty, let characters = event.charactersIgnoringModifiers, characters.count == 1 else {
                NSSound.beep(); return
            }
            completed = true
            completion(Shortcut(characters.lowercased(), modifiers))
        }
    }
}
