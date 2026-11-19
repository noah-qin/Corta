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

/// Folders named from outside Corta open a window each, its root pane
/// born in the folder: Finder's service, `open -a`, and a drop on the Dock
/// icon all arrive here, are checked off the main thread
/// (`FolderRequest`), and reach the window by its setup, so the child's
/// first winsize is its only one.
extension AppDelegate {
    /// `open -a Corta <folder>` and a folder dropped on the Dock icon,
    /// whether Corta was running or is launching for it. The Info.plist
    /// declares folders, viewer role, so the Dock accepts the drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        openFolders(urls)
    }

    /// The **New Corta Window Here** service (`NSServices` in the
    /// Info.plist; **New Corta Dev Window Here** in the development build):
    /// the folders Finder put on the pasteboard. Its selector is the
    /// service's `NSMessage`.
    // periphery:ignore - reached by selector, the Info.plist's NSMessage
    @objc func openFolderService(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = L10n.text("folder.refused.nothing") as NSString
            return
        }
        openFolders(urls)
    }

    /// The file URLs on a service's pasteboard; text is never read from it.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// One window per folder that passes the check, at most
    /// `FolderRequest.maximumFolders`; one alert for the rest.
    func openFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Arriving before the first windows: this folder's window replaces
        // the fresh one the launch would open.
        if !initialWindowsOpened { launchedForFolder = true }
        let checked = Array(urls.prefix(FolderRequest.maximumFolders))
        let excess = urls.count - checked.count
        FolderRequest.check(checked) { [weak self] outcomes in
            self?.finishOpeningFolders(outcomes, excess: excess)
        }
    }

    private func finishOpeningFolders(_ outcomes: [FolderRequest.Outcome], excess: Int) {
        // During launch the windows wait for the first ones, so a restore
        // does not cover them, and so does the alert: one run before
        // launching finishes was dismissed before it showed.
        guard initialWindowsOpened else {
            foldersAwaitingLaunch.append((outcomes, excess))
            return
        }
        var refusals: [FolderRequest.Refusal] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let path): openFolderWindow(path)
            case .failure(let refusal): refusals.append(refusal)
            }
        }
        guard !refusals.isEmpty || excess > 0 else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.text("folder.refused.title")
        alert.informativeText = Self.refusalText(refusals, excess: excess)
        alert.present(for: NSApp.keyWindow) { _ in }
    }

    /// The requests checked while the launch was still opening its first
    /// windows, answered now.
    func openFoldersAwaitingLaunch() {
        let waiting = foldersAwaitingLaunch
        foldersAwaitingLaunch = []
        for request in waiting { finishOpeningFolders(request.outcomes, excess: request.excess) }
    }

    private func openFolderWindow(_ path: String) {
        NSApp.activate()
        let window = open(setup: Self.folderWindowSetup(path))?.window
        // Activation is asynchronous: from Finder's service, Finder's window
        // would otherwise stay ahead of the new one.
        window?.orderFrontRegardless()
    }

    /// A checked folder's window: its directory and nothing else — no
    /// preset, no restore, no text for the child. The folder was checked
    /// just now, so the pane does not wait on it a second time.
    static func folderWindowSetup(_ path: String) -> SplitViewController.Setup {
        SplitViewController.Setup(directoriesChecked: true, workingDirectory: path)
    }

    /// Why each refused path opened nothing, a paragraph each.
    static func refusalText(_ refusals: [FolderRequest.Refusal], excess: Int) -> String {
        var lines = refusals.map { refusal -> String in
            switch refusal {
            case .notLocal(let path): L10n.format("folder.refused.notLocal", path)
            case .missing(let path): L10n.format("folder.refused.missing", abbreviated(path))
            case .notFolder(let path): L10n.format("folder.refused.notFolder", abbreviated(path))
            case .unreadable(let path): L10n.format("folder.refused.unreadable", abbreviated(path))
            case .noAnswer(let path): L10n.format("folder.refused.noAnswer", abbreviated(path))
            }
        }
        if excess > 0 { lines.append(L10n.format("folder.refused.tooMany", FolderRequest.maximumFolders, excess)) }
        return lines.joined(separator: "\n\n")
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
