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

/// The browser's sheets: a transfer conflict, and naming a new folder or a rename.
extension SFTPBrowserView {
    // MARK: - Conflict sheet

    struct ConflictSheet: View {
        let prompt: SFTPBrowserModel.ConflictPrompt
        let model: SFTPBrowserModel

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("sftp.conflict.title"))
                    .font(.headline)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button(L10n.text("sftp.conflict.skip")) {
                        model.resolveConflict(prompt.id, choice: .skip)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("sftp.conflict.keepBoth")) {
                        model.resolveConflict(prompt.id, choice: .keepBoth)
                    }
                    if prompt.canResume {
                        Button(L10n.text("sftp.conflict.resume")) {
                            model.resolveConflict(prompt.id, choice: .resume)
                        }
                    }
                    Button(L10n.text("sftp.conflict.overwrite")) {
                        model.resolveConflict(prompt.id, choice: .overwrite)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }

        private var message: String {
            let key =
                prompt.partialOnly
                ? "sftp.conflict.message.partial" : "sftp.conflict.message.destination"
            return L10n.format(
                key, prompt.path, prompt.destinationDescription, prompt.sourceDescription)
        }
    }

    // MARK: - New directory / rename sheet

    struct TextPromptSheet: View {
        let prompt: SFTPBrowserModel.TextPrompt
        let model: SFTPBrowserModel
        @State private var text: String

        init(prompt: SFTPBrowserModel.TextPrompt, model: SFTPBrowserModel) {
            self.prompt = prompt
            self.model = model
            _text = State(initialValue: prompt.initialText)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.title)
                    .font(.headline)
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitTextPrompt(text) }
                HStack {
                    Spacer()
                    Button(L10n.text("common.cancel")) { model.textPrompt = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(prompt.title) { model.commitTextPrompt(text) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 320)
        }
    }
}
