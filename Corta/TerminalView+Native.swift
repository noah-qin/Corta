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
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPaths(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPaths(from: sender).isEmpty ? [] : .copy
    }

    /// Inserts the paths as quoted text at the prompt, as if typed; the shell
    /// decides what they mean.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let paths = droppedPaths(from: sender)
        guard !paths.isEmpty else { return false }
        onDropPaths?(paths)
        return true
    }

    private func droppedPaths(from sender: any NSDraggingInfo) -> [String] {
        Self.droppedPaths(from: sender.draggingPasteboard)
    }

    /// Apart from `NSDraggingInfo`, so tests need no synthetic Finder drag.
    static func droppedPaths(from pasteboard: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
        return urls.map(\.path)
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
