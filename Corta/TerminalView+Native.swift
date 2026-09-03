import Cocoa

/// M6.15 — the native integrations a self-drawn toolkit cannot get for free,
/// and that being an ordinary AppKit view makes cheap.
///
/// Dropping a file at the prompt, looking a word up with a force touch, and
/// the Services menu acting on the selection are all things macOS already
/// knows how to do; each one here is the small amount of plumbing that lets
/// it reach a Metal surface with no text system behind it.
extension TerminalView {
    // MARK: - Dragging a file or folder in

    /// Registers for file drags. Called from `commonInit`.
    func registerForFileDrags() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPaths(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPaths(from: sender).isEmpty ? [] : .copy
    }

    /// A drop inserts the paths as text at the prompt — quoted, space
    /// separated — rather than doing anything with the files. The shell is
    /// what decides what a path means, and typing it is what the user would
    /// have done by hand.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let paths = droppedPaths(from: sender)
        guard !paths.isEmpty else { return false }
        onDropPaths?(paths)
        return true
    }

    private func droppedPaths(from sender: any NSDraggingInfo) -> [String] {
        Self.droppedPaths(from: sender.draggingPasteboard)
    }

    /// Kept separate from `NSDraggingInfo` so the pasteboard boundary can
    /// be exercised without synthesising a Finder drag in a unit test.
    static func droppedPaths(from pasteboard: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
        return urls.map(\.path)
    }

    // MARK: - Look Up (force touch, three-finger tap)

    /// AppKit routes a force touch here. A text view answers by looking up
    /// the word under the cursor; this view has no text system, so it asks
    /// the controller for the word the same way a double-click selection
    /// does, and hands it to the same dictionary panel.
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

    /// The Services menu asks who can supply and receive data before it
    /// builds itself. Answering for `.string` when there is a selection is
    /// what makes the terminal's selection appear in Services items.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && onServicesSelection?() != nil)
        // A service that returns text is a paste: the bytes go to the child
        // exactly as a ⌘V would send them.
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
