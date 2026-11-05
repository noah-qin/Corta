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

/// Files that arrived after the pane they were dropped on closed, or moved on
/// to another program. Their paths are the user's to use: they are never typed
/// into the terminal, and the copies stay until a later launch cleans them up.
@MainActor
enum FileDropUndelivered {
    /// The alert's text, cleaned like any path (a file name can hold controls),
    /// at most `limit` paths.
    static func message(for urls: [URL], limit: Int = 10) -> String {
        let shown = urls.prefix(limit).map { Paste.sanitized($0.path) }.joined(separator: "\n")
        let hidden = urls.count - min(urls.count, limit)
        return hidden > 0 ? shown + "\n" + L10n.format("drop.undelivered.more", hidden) : shown
    }

    static func present(_ result: FileDropRequest.Result, in window: NSWindow?) {
        guard !result.urls.isEmpty else {
            FileDropStorage.remove(result.directory)
            return
        }
        presenter(result.urls, window)
    }

    /// Replaced by tests: with no window the alert is app-modal, and would
    /// never return in a test host.
    static var presenter: @MainActor ([URL], NSWindow?) -> Void = showAlert

    private static func showAlert(for urls: [URL], in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("drop.undelivered.title")
        alert.informativeText = message(for: urls)
        alert.addButton(withTitle: L10n.text("common.close"))
        alert.addButton(withTitle: L10n.text("sftp.transfer.showInFinder"))
        alert.present(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }
}
