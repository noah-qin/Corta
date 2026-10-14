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

/// A user-entered destination becomes argv for system OpenSSH, never shell text.
nonisolated enum SSHDestination {
    static func preset(for target: SSHTarget) -> Preset {
        var preset = Preset(name: target.displayName)
        preset.shell = "/usr/bin/ssh"
        preset.arguments = target.sshArguments
        preset.connectTarget = target
        return preset
    }
}

/// What a connect dialog is for: a terminal over SSH, or the file browser
/// over SFTP. One form serves both, so the two read as the same task.
nonisolated enum RemoteConnectMode: Equatable, Sendable {
    case ssh, sftp

    var title: String {
        switch self {
        case .ssh: L10n.text("ui.ssh.title")
        case .sftp: L10n.text("ui.connect.sftp.title")
        }
    }

    /// The same symbols the window toolbar uses for the two buttons.
    var symbol: String {
        switch self {
        case .ssh: "network"
        case .sftp: "folder"
        }
    }
}

/// The Connect dialog, for SSH and for SFTP.
///
/// A sheet on the window it was asked from — the toolbar's buttons, or
/// Settings ▸ Connections — so it reads as part of that window's task; a
/// free-standing panel only when no window is key (the menu, with every
/// window closed). A plain window background either way: Liquid Glass is
/// the control layer floating over content, not a dialog's backdrop.
@MainActor
final class RemoteConnectController: NSWindowController {
    static let shared = RemoteConnectController()
    private let draft = RemoteConnectDraft()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(
            rootView: RemoteConnectSheet(draft: draft) { [weak self] mode, fields in
                self?.connect(mode: mode, fields: fields)
            })
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) { show(.ssh, sender: sender) }

    func show(_ mode: RemoteConnectMode, sender: Any?) {
        guard let window else { return }
        if window.isVisible {
            (window.sheetParent ?? window).makeKeyAndOrderFront(sender)
            return
        }
        // A fresh dialog each time: a host left over from the last one is a
        // connection nobody asked for.
        draft.reset(mode: mode)
        window.title = mode.title
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible,
            parent.attachedSheet == nil, !(parent is NSPanel)
        {
            parent.beginSheet(window)
        } else {
            window.center()
            showWindow(sender)
            window.makeKeyAndOrderFront(sender)
        }
        NSApp.activate()
    }

    override func close() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            super.close()
        }
    }

    /// Validated here, at the boundary: a problem keeps the dialog open and
    /// is what it shows. Nil once the dialog may close.
    private func connect(mode: RemoteConnectMode, fields: SSHTargetFields) -> SSHTarget.Problem? {
        let target: SSHTarget
        switch fields.target {
        case .success(let value): target = value
        case .failure(let problem): return problem
        }
        close()
        switch mode {
        case .ssh:
            RecentHostsStore.shared.record(target)
            (NSApp.delegate as? AppDelegate)?.launchPreset(
                SSHDestination.preset(for: target), inNewWindow: true)
        case .sftp:
            // Recorded once connected, by the browser.
            SFTPBrowserController.open(target)
        }
        return nil
    }
}

/// What the dialog holds while it is open, owned by the controller so each
/// showing starts empty.
@MainActor @Observable
final class RemoteConnectDraft {
    var mode: RemoteConnectMode = .ssh
    var fields = SSHTargetFields()
    var problem: SSHTarget.Problem?
    /// Bumped on reset, so the host field takes focus again.
    var generation = 0

    func reset(mode: RemoteConnectMode) {
        self.mode = mode
        fields = SSHTargetFields()
        problem = nil
        generation += 1
    }
}

/// The dialog's content: the shared form, with Cancel.
private struct RemoteConnectSheet: View {
    @Bindable var draft: RemoteConnectDraft
    let connect: (RemoteConnectMode, SSHTargetFields) -> SSHTarget.Problem?

    var body: some View {
        RemoteConnectForm(
            mode: draft.mode, fields: $draft.fields,
            error: draft.problem.map(RemoteConnectForm.message),
            focusGeneration: draft.generation,
            onCancel: { RemoteConnectController.shared.close() },
            onConnect: { draft.problem = connect(draft.mode, draft.fields) })
            .onChange(of: draft.fields) { draft.problem = nil }
            .padding(20)
            .frame(width: 460)
    }
}


/// The connect form both dialogs and the file browser's own host step use:
/// a heading, the host, user, port and key, the hosts it can suggest, what
/// went wrong if anything did, and what the connection relies on.
struct RemoteConnectForm: View {
    let mode: RemoteConnectMode
    @Binding var fields: SSHTargetFields
    /// A line above the fields — where a prefilled name came from.
    var notice: String?
    var error: String?
    var focusGeneration = 0
    var onCancel: (() -> Void)?
    let onConnect: () -> Void

    @FocusState private var hostFocused: Bool
    @State private var aliases: [String] = []
    @State private var recents: [SSHTarget] = []
    @State private var picked: Suggestion?

    /// A row in the suggestion well: a recent connection fills every
    /// field it was made with; an alias only the host, leaving the rest to
    /// its `~/.ssh/config` entry.
    enum Suggestion: Hashable {
        case recent(SSHTarget)
        case alias(String)

        var name: String {
            switch self {
            case .recent(let target): target.displayName
            case .alias(let name): name
            }
        }

        var fields: SSHTargetFields {
            switch self {
            case .recent(let target): SSHTargetFields(target)
            case .alias(let name): SSHTargetFields(host: name)
            }
        }
    }

    /// The text a problem is shown as.
    static func message(_ problem: SSHTarget.Problem) -> String {
        switch problem {
        case .host: L10n.text("ui.connect.problem.host")
        case .user: L10n.text("ui.connect.problem.user")
        case .userTwice: L10n.text("ui.connect.problem.userTwice")
        case .port: L10n.text("ui.connect.problem.port")
        case .identityFile: L10n.text("ui.connect.problem.identityFile")
        case .identityFileMissing: L10n.text("ui.connect.problem.identityFileMissing")
        }
    }

    var body: some View {
        // Computed once per body: each keystroke narrows the lists.
        let shown = visibleSuggestions
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(mode.title).font(.headline)
            }
            if let notice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField(L10n.text("ui.ssh.host"), text: $fields.host, prompt: Text(verbatim: "hostname"))
                    .focused($hostFocused)
                    .onSubmit(onConnect)
                    // ↓ and ↑ walk the suggestions from the field, the way an
                    // address bar's do; Return then connects to the one picked.
                    .onKeyPress(.downArrow) { stepSuggestion(by: 1) }
                    .onKeyPress(.upArrow) { stepSuggestion(by: -1) }
                    .accessibilityIdentifier("connect-host")
                TextField(L10n.text("ui.connect.user"), text: $fields.user,
                          prompt: Text(L10n.text("ui.connect.fromConfig")))
                    .onSubmit(onConnect)
                    .accessibilityIdentifier("connect-user")
                TextField(L10n.text("ui.ssh.port"), text: $fields.port, prompt: Text(verbatim: "22"))
                    .frame(width: 90)
                    .onSubmit(onConnect)
                    .help(L10n.text("ui.ssh.portDefault"))
                    .accessibilityIdentifier("connect-port")
                LabeledContent(L10n.text("ui.connect.identity")) { identityRow }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            if !shown.recents.isEmpty || !shown.aliases.isEmpty {
                suggestions(shown)
            }
            if let error {
                // Said in words with a symbol, never by colour alone.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let onCancel {
                    Button(L10n.text("common.cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(L10n.text("sftp.host.connect"), action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fields.isEmpty)
            }
            .controlSize(.large)
        }
        .onAppear { hostFocused = true }
        .onChange(of: focusGeneration) { hostFocused = true }
        .task(id: focusGeneration) {
            recents = RecentHostsStore.shared.targets
            // A file read, off the main actor; small, bounded, read-only.
            aliases = await Task.detached(priority: .userInitiated) { SSHConfigHosts.aliases() }.value
        }
    }

    /// The chosen key's path, or what applies without one, with Choose… and
    /// a way back to the default.
    private var identityRow: some View {
        HStack(spacing: 6) {
            Text(fields.identityFile.isEmpty
                 ? L10n.text("ui.connect.identityDefault")
                 : (fields.identityFile as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(fields.identityFile.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(fields.identityFile)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !fields.identityFile.isEmpty {
                Button {
                    fields.identityFile = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.text("ui.connect.identityClear"))
                .accessibilityLabel(L10n.text("ui.connect.identityClear"))
            }
            Button(L10n.text("ui.connect.identityChoose"), action: chooseIdentity)
                .accessibilityIdentifier("connect-identity-choose")
        }
    }

    /// An open panel in `~/.ssh`, hidden files shown. A `.pub` chosen by
    /// mistake becomes its private half when that file is there — ssh
    /// signs with the private key, never the public one.
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L10n.text("ui.connect.identityPanel")
        // The real home: the `ssh` this spawns reads the real `~/.ssh`.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        if url.pathExtension == "pub" {
            let privateHalf = url.deletingPathExtension().path
            if FileManager.default.isReadableFile(atPath: privateHalf) { path = privateHalf }
        }
        fields.identityFile = path
    }

    private var help: String {
        switch mode {
        case .ssh: L10n.text("ui.ssh.help")
        case .sftp: L10n.text("ui.sftp.authHelp")
        }
    }

    /// What has been typed narrows the list, the way an address field's
    /// suggestions do; a picked suggestion shows every one again.
    private var filter: String {
        pickedIsCurrent ? "" : fields.host.trimmingCharacters(in: .whitespaces)
    }

    /// The fields still hold the picked suggestion's, unedited.
    private var pickedIsCurrent: Bool {
        picked.map { $0.fields == fields } ?? false
    }

    /// The suggestions the typed host leaves, recents first; an alias that
    /// is also a recent is listed once, as the recent.
    private var visibleSuggestions: (recents: [Suggestion], aliases: [Suggestion]) {
        let filter = filter
        let recentHosts = Set(recents.map(\.displayName))
        return (
            Self.matching(recents.map(Suggestion.recent), filter),
            Self.matching(aliases.filter { !recentHosts.contains($0) }.map(Suggestion.alias), filter))
    }

    private func pick(_ suggestion: Suggestion) {
        picked = suggestion
        fields = suggestion.fields
    }

    /// Moves the pick through the visible suggestions, recents first.
    private func stepSuggestion(by delta: Int) -> KeyPress.Result {
        let shown = visibleSuggestions
        let suggestions = shown.recents + shown.aliases
        guard !suggestions.isEmpty else { return .ignored }
        let current = picked.flatMap { suggestions.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), suggestions.count - 1) }
            ?? (delta > 0 ? 0 : suggestions.count - 1)
        pick(suggestions[next])
        return .handled
    }

    static func matching(_ suggestions: [Suggestion], _ filter: String) -> [Suggestion] {
        guard !filter.isEmpty else { return suggestions }
        return suggestions.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// The suggestions, in a rounded well like the fields above: a click
    /// fills the fields, a double-click connects, the menu forgets a recent
    /// host. Drawn as plain rows — a `List` brought a square frame or its
    /// own insets, and either sat badly in a rounded sheet.
    private func suggestions(_ shown: (recents: [Suggestion], aliases: [Suggestion])) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                suggestionSection(L10n.text("ui.connect.recent"), shown.recents, symbol: "clock")
                suggestionSection(L10n.text("ui.connect.sshConfig"), shown.aliases, symbol: "doc.text")
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.suggestionHeight(shown))
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder
    private func suggestionSection(_ title: String, _ suggestions: [Suggestion], symbol: String) -> some View {
        if !suggestions.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: Self.headerHeight, alignment: .bottomLeading)
            ForEach(suggestions, id: \.self) { suggestion in
                suggestionRow(suggestion, symbol: symbol)
            }
        }
    }

    private func suggestionRow(_ suggestion: Suggestion, symbol: String) -> some View {
        let isPicked = picked == suggestion && pickedIsCurrent
        return Button {
            pick(suggestion)
        } label: {
            Label(suggestion.name, systemImage: symbol)
                .labelStyle(SuggestionLabelStyle(isPicked: isPicked))
                .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .background(
                    isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            pick(suggestion)
            onConnect()
        })
        .contextMenu {
            if case .recent(let target) = suggestion {
                Button(L10n.text("ui.connect.removeRecent")) {
                    RecentHostsStore.shared.remove(target)
                    recents = RecentHostsStore.shared.targets
                }
            }
        }
    }

    private struct SuggestionLabelStyle: LabelStyle {
        let isPicked: Bool

        func makeBody(configuration: LabelStyleConfiguration) -> some View {
            HStack(spacing: 8) {
                // White on the selection, or it vanished into the tint.
                configuration.icon
                    .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 16)
                configuration.title.lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 20

    /// Exactly what there is, up to about six rows; then it scrolls.
    private static func suggestionHeight(_ shown: (recents: [Suggestion], aliases: [Suggestion])) -> CGFloat {
        let rows = shown.recents.count + shown.aliases.count
        let headers = (shown.recents.isEmpty ? 0 : 1) + (shown.aliases.isEmpty ? 0 : 1)
        let content = CGFloat(rows) * (Self.rowHeight + 1) + CGFloat(headers) * (Self.headerHeight + 1) + 12
        return min(190, content)
    }
}
