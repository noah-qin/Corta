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

/// The dialogs an SFTP connection's ssh asks through (`SSHAskpass`): a
/// sheet on the browser window for the host, or else on the window the
/// user is working in. The prompt is shown as ssh or the server wrote it —
/// cleaned, and said to come from them — and the answer goes back to ssh
/// and nowhere else: not stored, not logged.
@MainActor
enum SSHAskpassPrompter {
    /// Posted with the host (`SSHTarget.displayName`) when a password is
    /// refused: the broker ends that connection's ssh, and a window waiting
    /// on it goes back to its host field rather than reporting a failure.
    /// Two windows to the same place with different keys share the name and
    /// both go back — rare, and Connect is one click away.
    static let refusedNotification = Notification.Name("CortaSSHAskpassRefused")

    /// Nil is a refusal. Task cancellation — ssh no longer waiting — takes
    /// the sheet down and refuses.
    static func ask(_ question: SSHAskpass.Question, host: String, prompt: String) async -> String? {
        // With every window closed — a remote-edit save reconnecting — the
        // question gets a window of its own rather than a silent refusal.
        let endsConnection = question == .secret && SSHAskpass.refusalEndsConnection(kind: .secret, prompt: prompt)
        let found = window(for: host)
        let standalone = found == nil ? makeStandaloneWindow() : nil
        guard let window = found ?? standalone else {
            // Refused unasked: the broker still ends the connection.
            if endsConnection { NotificationCenter.default.post(name: refusedNotification, object: host) }
            return nil
        }
        defer { standalone?.close() }
        // In the background the sheet is out of sight: bounce until the
        // user comes, and stop once the question is gone.
        let attention = NSApp.isActive ? nil : NSApp.requestUserAttention(.criticalRequest)
        defer { if let attention { NSApp.cancelUserAttentionRequest(attention) } }
        let alert = makeAlert(question, host: host, prompt: prompt)
        let field = alert.accessoryView as? NSSecureTextField
        let answer = await answer(alert, field: field, question: question, on: window)
        if endsConnection, answer == nil, !Task.isCancelled {
            NotificationCenter.default.post(name: refusedNotification, object: host)
        }
        return answer
    }

    private static func answer(
        _ alert: NSAlert, field: NSSecureTextField?, question: SSHAskpass.Question, on window: NSWindow
    ) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                alert.beginSheetModal(for: window) { response in
                    guard response == acceptResponse(question) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    switch question {
                    case .secret: continuation.resume(returning: field?.stringValue ?? "")
                    case .hostKey, .confirm: continuation.resume(returning: "yes")
                    case .notify: continuation.resume(returning: nil)
                    }
                    // The field's text is not kept past the answer.
                    field?.stringValue = ""
                }
                if let field { alert.window.makeFirstResponder(field) }
                // Cancelled before the sheet was up: `onCancel` already ran,
                // with nothing yet to end.
                if Task.isCancelled { window.endSheet(alert.window, returnCode: .cancel) }
            }
        } onCancel: {
            Task { @MainActor in
                window.endSheet(alert.window, returnCode: .cancel)
            }
        }
    }

    /// A small titled window to hang the sheet on, when Corta has none open.
    private static func makeStandaloneWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 1),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Corta"
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// The browser window for `host` when there is one, else the window in
    /// front.
    private static func window(for host: String) -> NSWindow? {
        if let browser = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "Corta.SFTPBrowser" && $0.title == host && $0.isVisible
        }) {
            return browser
        }
        return [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { $0.isVisible && !($0 is NSPanel) }
            ?? NSApp.windows.first { $0.isVisible && $0.windowController is TerminalWindowController }
    }

    /// The button that answers yes — the second for a host key, whose
    /// default is to refuse.
    static func acceptResponse(_ question: SSHAskpass.Question) -> NSApplication.ModalResponse {
        question == .hostKey ? .alertSecondButtonReturn : .alertFirstButtonReturn
    }

    static func makeAlert(_ question: SSHAskpass.Question, host: String, prompt: String) -> NSAlert {
        let alert = NSAlert()
        let source = L10n.text("askpass.source")
        switch question {
        case .secret:
            // One title, then ssh's own question and where it came from in
            // one line: the prompt usually names the host again, so a
            // separate paragraph for each said the same thing three times.
            alert.icon = symbolIcon("lock.fill", tint: .controlAccentColor)
            alert.messageText = L10n.format("askpass.secret.title", host)
            alert.informativeText = "“\(prompt)” · " + L10n.text("askpass.source.short")
            alert.addButton(withTitle: L10n.text("askpass.continue"))
            // Cancel ends the connection (the broker), so it says so; for a
            // key's passphrase it only skips that key.
            alert.addButton(withTitle: L10n.text(
                SSHAskpass.refusalEndsConnection(kind: .secret, prompt: prompt)
                    ? "askpass.cancelConnection" : "common.cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = placeholder(for: prompt)
            field.setAccessibilityIdentifier("askpass-answer")
            field.setAccessibilityLabel(L10n.format("askpass.secret.title", host))
            alert.accessoryView = field
        case .hostKey:
            alert.alertStyle = .warning
            alert.icon = symbolIcon("exclamationmark.shield.fill", tint: .systemOrange)
            alert.messageText = L10n.format("askpass.hostKey.title", host)
            alert.informativeText = prompt + "\n\n" + L10n.text("askpass.hostKey.advice")
            // Cancel is the default: Return must not trust a key unread.
            alert.addButton(withTitle: L10n.text("common.cancel"))
            alert.addButton(withTitle: L10n.text("askpass.hostKey.trust"))
        case .confirm:
            alert.icon = symbolIcon("key.fill", tint: .controlAccentColor)
            alert.messageText = L10n.format("askpass.confirm.title", host)
            alert.informativeText = prompt + "\n\n" + source
            alert.addButton(withTitle: L10n.text("askpass.confirm.allow"))
            alert.addButton(withTitle: L10n.text("askpass.confirm.deny"))
        case .notify:
            alert.messageText = L10n.format("askpass.notify.title", host)
            alert.informativeText = prompt
            alert.addButton(withTitle: L10n.text("askpass.notify.hide"))
        }
        return alert
    }

    /// What the field holds, named from ssh's question: a key's passphrase,
    /// a password, or — a one-time code, a server's own question — an answer.
    static func placeholder(for prompt: String) -> String {
        let lowered = prompt.lowercased()
        if lowered.contains("passphrase") { return L10n.text("askpass.placeholder.passphrase") }
        if lowered.contains("password") { return L10n.text("askpass.placeholder.password") }
        return L10n.text("askpass.placeholder.answer")
    }

    /// A symbol in the alert's icon place, instead of the app icon: the
    /// question is about a connection, not about Corta.
    /// Drawn small in the middle of the alert's 64-point icon square: a
    /// symbol handed over as it is was scaled up to fill it.
    private static func symbolIcon(_ name: String, tint: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        let side: CGFloat = 64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2,
                width: size.width, height: size.height))
            return true
        }
    }
}
