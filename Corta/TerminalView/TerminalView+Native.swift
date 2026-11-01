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

/// File drops, Look Up and Services: the plumbing that lets macOS reach a
/// Metal surface with no text system.
extension TerminalView {
    // MARK: - Dragging a file or folder in

    func registerForFileDrags() {
        // File promises: the SFTP browser's rows, taken as a remote path on
        // their own host (`SFTPRemoteDrag`); any other application's, received
        // after the drop (`ExternalFileDrop`). Neither is read while tracking.
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(from: sender.draggingPasteboard, isLocalDrag: sender.draggingSource != nil) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(from: sender.draggingPasteboard, isLocalDrag: sender.draggingSource != nil) ? .copy : []
    }

    /// Inserts the paths as quoted text at the prompt, as if typed; the shell
    /// decides what they mean. Resident paths go in now; a promised file is
    /// received first and its path goes in when the source has written it.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let drop = drop(from: pasteboard, isLocalDrag: sender.draggingSource != nil)
        guard !drop.paths.isEmpty || drop.hasPromise else { return false }
        if sender.draggingSource != nil, let token = SFTPRemoteDrag.currentToken,
           SFTPRemoteDrag.isFilePromise(pasteboard.types ?? []) {
            SFTPRemoteDrag.end(token: token)
        }
        if !drop.paths.isEmpty { onDropPaths?(drop.paths) }
        if drop.hasPromise {
            ExternalFileDrop.receivePromisedFiles(on: pasteboard) { [weak self] paths in
                guard !paths.isEmpty else { return }
                self?.onDropPaths?(paths)
            }
        }
        return true
    }

    /// A drag from this app's file browser ends here as well as at its source.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        guard sender.draggingSource != nil, SFTPRemoteDrag.matchesRecordedLink(sender.draggingPasteboard),
              let token = SFTPRemoteDrag.currentToken else { return }
        SFTPRemoteDrag.end(token: token)
    }

    /// What a drag holds for this pane, read without asking any source to
    /// write: the browser's own row as remote paths on its host (none on
    /// another host), resident file URLs as local paths, and whether another
    /// application's file promise is there to receive after the drop.
    struct Drop: Equatable {
        var paths: [String]
        var hasPromise: Bool
    }

    /// Kept apart from `NSDraggingInfo` so a real table writer can exercise
    /// drag negotiation without synthesizing a window-server drag session.
    func drop(from pasteboard: NSPasteboard, isLocalDrag: Bool) -> Drop {
        let types = pasteboard.types ?? []
        if SFTPRemoteDrag.isFilePromise(types), isLocalDrag,
           let url = SFTPRemoteDrag.url(forPasteboardTypes: types) {
            return Drop(paths: remotePathsForDrop?([url]) ?? [], hasPromise: false)
        }
        guard types.contains(.fileURL) || SFTPRemoteDrag.isFilePromise(types) else {
            return Drop(paths: [], hasPromise: false)
        }
        return Drop(paths: ExternalFileDrop.residentPaths(on: pasteboard),
                    hasPromise: ExternalFileDrop.hasExternalPromise(on: pasteboard))
    }

    /// The paths known before the drop; a promise contributes none yet.
    func droppedPaths(from pasteboard: NSPasteboard, isLocalDrag: Bool) -> [String] {
        drop(from: pasteboard, isLocalDrag: isLocalDrag).paths
    }

    /// Whether tracking shows the drop as possible.
    func acceptsDrop(from pasteboard: NSPasteboard, isLocalDrag: Bool) -> Bool {
        let drop = drop(from: pasteboard, isLocalDrag: isLocalDrag)
        return !drop.paths.isEmpty || drop.hasPromise
    }

    /// Apart from `NSDraggingInfo`, so tests need no synthetic Finder drag.
    static func droppedPaths(from pasteboard: NSPasteboard) -> [String] {
        ExternalFileDrop.residentPaths(on: pasteboard)
    }

    // MARK: - Look Up (force touch, three-finger tap)

    /// A force touch: the controller supplies the word, as for a
    /// double-click, and the dictionary panel shows it.
    override func quickLook(with event: NSEvent) {
        guard let (word, origin) = onLookUp?(convert(event.locationInWindow, from: nil)),
            !word.isEmpty
        else {
            super.quickLook(with: event)
            return
        }
        showDefinition(for: NSAttributedString(string: word), at: origin)
    }

    // MARK: - Services

    /// Answering for `.string` with a selection puts it in Services.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && onServicesSelection?() != nil)
        // Returned text is a paste, sent as ⌘V would.
        let canReturn = returnType == nil || returnType == .string
        if canSend && canReturn { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = onServicesSelection?() else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let text = pasteboard.string(forType: .string) else { return false }
        onServicesInsert?(text)
        return true
    }
}
