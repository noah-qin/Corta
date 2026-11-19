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

/// What the compose field needs from its pane: the view it floats in, the
/// session a send is meant for, and the paste path that sends it.
protocol PaneComposerHost: AnyObject {
    /// The pane's own view; the field is its subview.
    var view: NSView { get }
    /// Where the keyboard goes back to when the field closes.
    var terminalView: TerminalView! { get }
    /// The top of the grid, below any window chrome or pane header.
    var topInset: CGFloat { get }
    var session: TerminalSession! { get }
    /// False for a pane whose setup failed.
    var isOperable: Bool { get }
    /// `insertAsPaste`, the one route into the child the field uses.
    var commands: PaneCommands { get }
}

/// A native text field for writing a prompt, sent to the pane as a paste.
///
/// Opened only on request (Edit ▸ Compose Text…, the palette, a binding) and
/// never offered by itself; while it is closed nothing about typing into the
/// pane changes. An `NSTextView`, so input methods, undo, spelling and
/// dictation are the system's, not whatever the program in the pane manages.
///
/// ⌘Return sends and Return is a newline: an input method that commits on
/// Return can never send by accident. Esc closes the field — unless an input
/// method is composing, when Esc is the composition's to cancel (#522's rule).
///
/// Sending is `PaneCommands.insertAsPaste`: sanitised, bracketed when the
/// child asked, and subject to the paste warning. No Return is appended; the
/// user submits in the program. The draft belongs to this pane, survives
/// closing the field without sending, and is never written to disk.
final class PaneComposer: NSObject, NSMenuItemValidation {
    weak var host: PaneComposerHost?

    /// The hosted `ComposerView`, while the field is open.
    private(set) var panel: NSView?
    private(set) var textView: ComposerTextView?
    private var topConstraint: NSLayoutConstraint?
    let model = ComposerModel()

    /// What was written and not sent, kept while the field is closed. Memory
    /// only: a prompt can hold anything, and nothing of it reaches the disk.
    private(set) var draft = ""

    /// Gap between the field and the top of the grid.
    static let topMargin: CGFloat = 8
    static let sideMargin: CGFloat = 12
    /// Wide enough for a paragraph, narrow enough to read in a wide pane.
    static let maximumWidth: CGFloat = 760
    static let preferredHeight: CGFloat = 200

    init(host: PaneComposerHost? = nil) {
        self.host = host
    }

    var isOpen: Bool { panel != nil }

    // MARK: - Commands

    /// Edit ▸ Compose Text…, the palette and `bind.compose-text`.
    @objc func composeText(_: Any?) {
        show()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(composeText(_:)) else { return true }
        return canSend
    }

    /// A pane with a running session: a failed or ended pane has nobody to
    /// read the text.
    private var canSend: Bool {
        guard let host, host.isOperable, let session = host.session else { return false }
        return !session.isStopped
    }

    // MARK: - Showing and closing

    /// Opens the field over the pane with the draft in it, or gives an open
    /// field the keyboard again.
    func show() {
        guard let host, canSend else {
            NSSound.beep()
            return
        }
        if let textView {
            host.view.window?.makeFirstResponder(textView)
            return
        }
        let textView = ComposerTextView.make()
        textView.string = draft
        textView.onSend = { [weak self] in self?.send() }
        textView.onClose = { [weak self] in self?.close() }
        textView.onChange = { [weak self, weak textView] in
            self?.model.isEmpty = textView?.string.isEmpty ?? true
        }
        model.isEmpty = draft.isEmpty
        model.onSend = { [weak self] in self?.send() }
        model.onClose = { [weak self] in self?.close() }

        let container = ComposerView.hostingView(model: model, scrollView: textView.enclosingScrollView!)
        let view = host.view
        view.addSubview(container)
        let top = container.topAnchor.constraint(
            equalTo: view.topAnchor, constant: host.topInset + Self.topMargin)
        // As wide as the pane allows, up to `maximumWidth`, centred; as tall
        // as preferred, short of the pane's bottom edge.
        let width = container.widthAnchor.constraint(
            equalTo: view.widthAnchor, constant: -2 * Self.sideMargin)
        width.priority = .defaultHigh
        let height = container.heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            top, width, height,
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Self.sideMargin),
            container.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Self.topMargin),
        ])
        topConstraint = top
        view.layoutSubtreeIfNeeded()

        // A fade, at once under Reduce Motion.
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SystemAccessibility.duration(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.animator().alphaValue = 1
        }
        panel = container
        self.textView = textView
        view.window?.makeFirstResponder(textView)
        textView.scrollToEndOfDocument(nil)
    }

    /// Closes the field, keeping what was written as the draft, and hands
    /// the keyboard back to the terminal.
    func close() {
        guard let textView else { return }
        textView.dropComposition()
        draft = textView.string
        dismiss()
        host?.view.window?.makeFirstResponder(host?.terminalView)
    }

    /// The pane is closing or starting a new session: the field goes and the
    /// keyboard is left where the caller puts it. The draft stays with the
    /// pane until the pane itself goes.
    func detach() {
        guard let textView else { return }
        textView.dropComposition()
        draft = textView.string
        dismiss()
    }

    private func dismiss() {
        panel?.removeFromSuperview()
        panel = nil
        textView = nil
        topConstraint = nil
    }

    /// The chrome above the pane can change while the field is open (a
    /// header appearing on a split); the field follows it.
    func place() {
        guard let top = topConstraint, let host else { return }
        let constant = host.topInset + Self.topMargin
        if top.constant != constant { top.constant = constant }
    }

    // MARK: - Sending

    /// The text, as a paste, to the session the pane has now. The field
    /// closes and the draft empties at once; a send that does not happen —
    /// the warning answered Cancel, the pane rebuilt with a new session
    /// meanwhile — gives the text back as the draft, unless something newer
    /// was written since.
    func send() {
        guard let textView else { return }
        // The input method's preedit is not text yet: only committed text goes.
        textView.dropComposition()
        let text = textView.string
        guard !text.isEmpty, canSend, let host, let session = host.session else {
            NSSound.beep()
            return
        }
        draft = ""
        textView.string = ""
        dismiss()
        host.view.window?.makeFirstResponder(host.terminalView)
        host.commands.insertAsPaste(
            text,
            // Meant for this session only: a pane rebuilt while the warning
            // was up has another one, which never asked for this text.
            validate: { [weak host] in host?.session === session },
            onDiscard: { [weak self] in
                guard let self, self.draft.isEmpty, self.textView?.string.isEmpty ?? true else { return }
                self.draft = text
                self.textView?.string = text
                self.model.isEmpty = false
            })
    }
}

/// The compose field's text view: an ordinary `NSTextView` for plain text,
/// whose only keys of its own are ⌘Return (send) and Esc (close).
final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}
    var onClose: () -> Void = {}
    var onChange: () -> Void = {}

    /// A plain-text view in its scroll view, set up for prose and code alike:
    /// no smart quotes, dashes or replacements, which would change what the
    /// program receives; spelling is underlined, never corrected.
    static func make() -> ComposerTextView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.setAccessibilityLabel(L10n.text("composer.label"))
        textView.setAccessibilityIdentifier("composer-text")
        textView.setAccessibilityHelp(L10n.text("composer.hint"))
        scroll.documentView = textView
        return textView
    }

    /// ⌘Return, on the main keyboard or the keypad, with no other modifier.
    static func isSendKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 else { return false }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }

    static func isCloseKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53 /* kVK_Escape */
            && event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control])
    }

    /// Whether this view acts on `event` itself. While an input method holds
    /// marked text every key is its own — Esc cancels the composition, Return
    /// commits it — so nothing is taken from it.
    func handlesKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText() else { return false }
        if Self.isSendKey(event) {
            onSend()
            return true
        }
        if Self.isCloseKey(event) {
            onClose()
            return true
        }
        return false
    }

    /// ⌘Return is a key equivalent: the window offers it here before the
    /// menus, and only the view with the keyboard answers.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isSendKey(event), handlesKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handlesKey(event) { return }
        super.keyDown(with: event)
    }

    /// Esc by another route (the key bindings' `cancelOperation:`); an
    /// `NSTextView` would otherwise start word completion.
    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        onClose()
    }

    override func didChangeText() {
        super.didChangeText()
        onChange()
    }

    /// Ends a composition without committing it: the preedit leaves the text
    /// and the input method is told to forget it.
    func dropComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        // The input method may have cleared it in answer; otherwise the
        // preedit is replaced with nothing here.
        guard hasMarkedText() else { return }
        setMarkedText(
            "", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        unmarkText()
    }
}
