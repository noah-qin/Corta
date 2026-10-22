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

    /// The file browser's own host step names itself by this.
    var title: String {
        switch self {
        case .ssh: L10n.text("ui.ssh.title")
        case .sftp: L10n.text("ui.connect.sftp.title")
        }
    }

    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .sftp: "folder"
        }
    }
}

/// The focused pane's own host, offered first: what the toolbar's Files
/// button did in one click, kept one Return away.
struct RemoteConnectPaneFiles {
    /// The host as Corta names it; nil when the pane is remote but no
    /// honest source names it.
    var host: String?
    var open: () -> Void
}

/// The Connect dialog, for a terminal and for files.
///
/// A sheet on the window it was asked from — the toolbar's button, or
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
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

    /// - Parameter paneFiles: the focused pane's host, when it is remote.
    func show(_ mode: RemoteConnectMode, sender: Any?, paneFiles: RemoteConnectPaneFiles? = nil) {
        guard let window else { return }
        if window.isVisible {
            (window.sheetParent ?? window).makeKeyAndOrderFront(sender)
            return
        }
        // A fresh dialog each time: a host left over from the last one is a
        // connection nobody asked for.
        draft.reset(mode: mode, paneFiles: paneFiles)
        window.title = L10n.text("ui.connect.title")
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
        if fields.isEmpty, mode == .sftp, let paneFiles = draft.paneFiles {
            close()
            paneFiles.open()
            return nil
        }
        let target: SSHTarget
        switch fields.target {
        case .success(let value): target = value
        case .failure(let problem): return problem
        }
        close()
        switch mode {
        case .ssh:
            // Recorded once the connection is established, by the pane
            // (`PaneRemote.watchForEstablishedConnection`).
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
    var paneFiles: RemoteConnectPaneFiles?
    /// Bumped on reset, so the host field takes focus again.
    var generation = 0

    func reset(mode: RemoteConnectMode, paneFiles: RemoteConnectPaneFiles? = nil) {
        self.mode = mode
        self.paneFiles = paneFiles
        fields = SSHTargetFields()
        problem = nil
        generation += 1
    }
}

/// The dialog's content: the shared form, with the Terminal / Files switch
/// and Cancel.
private struct RemoteConnectSheet: View {
    @Bindable var draft: RemoteConnectDraft
    let connect: (RemoteConnectMode, SSHTargetFields) -> SSHTarget.Problem?

    var body: some View {
        RemoteConnectForm(
            mode: draft.mode, modeSelection: $draft.mode, fields: $draft.fields,
            paneFiles: draft.paneFiles,
            error: draft.problem.map(RemoteConnectForm.message),
            focusGeneration: draft.generation,
            onCancel: { RemoteConnectController.shared.close() },
            onConnect: { draft.problem = connect(draft.mode, draft.fields) })
            .onChange(of: draft.fields) { draft.problem = nil }
            .padding(20)
            .frame(width: 480)
    }
}


/// The connect form the dialog and the file browser's own host step use: a
/// heading, the host, the hosts it can suggest, the user, port and key
/// under Advanced, what went wrong if anything did, and what the
/// connection relies on.
struct RemoteConnectForm: View {
    let mode: RemoteConnectMode
    /// The dialog's Terminal / Files switch; the browser has none.
    var modeSelection: Binding<RemoteConnectMode>?
    @Binding var fields: SSHTargetFields
    var paneFiles: RemoteConnectPaneFiles?
    /// A line above the fields — where a prefilled name came from.
    var notice: String?
    var error: String?
    var focusGeneration = 0
    var onCancel: (() -> Void)?
    let onConnect: () -> Void

    @FocusState private var hostFocused: Bool
    @State private var aliases: [String] = []
    @State private var hiddenGitHosts: [String] = []
    @State private var recents: [SSHTarget] = []
    @State private var picked: Suggestion?
    @State private var hovered: Suggestion?
    @State private var showsAdvanced = false

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
            header
            if let notice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let paneFiles {
                paneFilesRow(paneFiles)
            }
            TextField(L10n.text("ui.ssh.host"), text: $fields.host,
                      prompt: Text(L10n.text("ui.connect.hostPrompt")))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($hostFocused)
                .onSubmit(onConnect)
                // ↓ and ↑ walk the suggestions from the field, the way an
                // address bar's do; Return then connects to the one picked.
                .onKeyPress(.downArrow) { stepSuggestion(by: 1) }
                .onKeyPress(.upArrow) { stepSuggestion(by: -1) }
                .accessibilityLabel(L10n.text("ui.ssh.host"))
                .accessibilityIdentifier("connect-host")
            if !shown.recents.isEmpty || !shown.aliases.isEmpty {
                suggestions(shown)
            }
            advanced
            if let error {
                // Said in words with a symbol, never by colour alone.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let onCancel {
                    Button(L10n.text("common.cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(L10n.text("sftp.host.connect"), action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    // Empty in Files, Return opens the focused pane's host's.
                    .disabled(fields.isEmpty && !(paneFiles != nil && mode == .sftp))
            }
            .controlSize(.large)
        }
        .onAppear { hostFocused = true }
        .onChange(of: focusGeneration) {
            hostFocused = true
            showsAdvanced = false
        }
        // A picked recent made with a user, port or key shows them.
        .onChange(of: fields) {
            if !fields.user.isEmpty || !fields.port.isEmpty || !fields.identityFile.isEmpty,
                picked != nil
            {
                showsAdvanced = true
            }
        }
        .task(id: focusGeneration) {
            recents = RecentHostsStore.shared.targets
            // A file read, off the main actor; small, bounded, read-only.
            let found = await Task.detached(priority: .userInitiated) { SSHConfigHosts.suggestions() }.value
            aliases = found.hosts
            hiddenGitHosts = found.hiddenGitHosts
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: modeSelection == nil ? mode.symbol : "network")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(modeSelection == nil ? mode.title : L10n.text("ui.connect.title")).font(.headline)
            Spacer()
            if let modeSelection {
                Picker(L10n.text("ui.connect.modeLabel"), selection: modeSelection) {
                    Label(L10n.text("ui.connect.mode.terminal"), systemImage: "terminal").tag(RemoteConnectMode.ssh)
                    Label(L10n.text("ui.connect.mode.files"), systemImage: "folder").tag(RemoteConnectMode.sftp)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("connect-mode")
            }
        }
    }

    /// The focused pane's host, one Return away when the field is empty.
    private func paneFilesRow(_ paneFiles: RemoteConnectPaneFiles) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("ui.connect.thisPane"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(paneFiles.host ?? L10n.text("ui.connect.thisPaneUnknown"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(L10n.text("ui.connect.browsePaneFiles")) {
                RemoteConnectController.shared.close()
                paneFiles.open()
            }
            .accessibilityIdentifier("connect-pane-files")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    /// User, port and key: rarely changed, so out of the way, with what
    /// they hold said on the closed row.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Text(L10n.text("ui.connect.advanced")).font(.callout.weight(.medium))
                    if !showsAdvanced {
                        Text(advancedSummary)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connect-advanced")
            if showsAdvanced {
                Form {
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
                .padding(.leading, 16)
            }
        }
    }

    /// "User · Port · Private key", or what they are set to.
    private var advancedSummary: String {
        let user = fields.user.isEmpty ? L10n.text("ui.connect.user") : fields.user
        let port = fields.port.isEmpty ? L10n.text("ui.ssh.port") : L10n.format("ui.connect.portValue", fields.port)
        let key = fields.identityFile.isEmpty
            ? L10n.text("ui.connect.identity") : (fields.identityFile as NSString).lastPathComponent
        return [user, port, key].joined(separator: " · ")
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
    /// is also a recent is listed once, as the recent. A git host is never
    /// offered — not even one recorded by an older build.
    private var visibleSuggestions: (recents: [Suggestion], aliases: [Suggestion]) {
        let filter = filter
        let shownRecents = recents.filter { !SSHConfigHosts.isGitHost($0.host) }
        let recentHosts = Set(shownRecents.map(\.displayName))
        return (
            Self.matching(shownRecents.map(Suggestion.recent), filter),
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

    /// The suggestions, in a rounded well: a click fills the fields, a
    /// double-click connects; a recent host is forgotten from its ✕ or its
    /// menu. Drawn as plain rows — a `List` brought a square frame or its
    /// own insets, and either sat badly in a rounded sheet.
    private func suggestions(_ shown: (recents: [Suggestion], aliases: [Suggestion])) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                suggestionSection(L10n.text("ui.connect.recent"), shown.recents, symbol: "clock")
                suggestionSection(
                    L10n.text("ui.connect.sshConfig"), shown.aliases, symbol: "doc.text",
                    trailing: hiddenGitHosts.isEmpty
                        ? nil : L10n.format("ui.connect.gitHostsHidden", hiddenGitHosts.joined(separator: ", ")))
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.suggestionHeight(shown))
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder
    private func suggestionSection(
        _ title: String, _ suggestions: [Suggestion], symbol: String, trailing: String? = nil
    ) -> some View {
        if !suggestions.isEmpty {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(trailing)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.headerHeight, alignment: .bottom)
            ForEach(suggestions, id: \.self) { suggestion in
                suggestionRow(suggestion, symbol: symbol)
            }
        }
    }

    private func suggestionRow(_ suggestion: Suggestion, symbol: String) -> some View {
        let isPicked = picked == suggestion && pickedIsCurrent
        let detail = detail(for: suggestion)
        return Button {
            pick(suggestion)
        } label: {
            HStack(spacing: 8) {
                // White on the selection, or it vanished into the tint.
                Image(systemName: symbol)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.name).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isPicked ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(
                isPicked ? AnyShapeStyle(.tint)
                    : hovered == suggestion ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .overlay(alignment: .trailing) {
            if case .recent(let target) = suggestion, hovered == suggestion {
                Button {
                    forget(target)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help(L10n.text("ui.connect.removeRecent"))
                .accessibilityLabel(L10n.text("ui.connect.removeRecent"))
            }
        }
        .onHover { inside in
            if inside { hovered = suggestion } else if hovered == suggestion { hovered = nil }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            pick(suggestion)
            onConnect()
        })
        .contextMenu {
            if case .recent(let target) = suggestion {
                Button(L10n.text("ui.connect.removeRecent")) { forget(target) }
            }
        }
    }

    private func forget(_ target: SSHTarget) {
        RecentHostsStore.shared.remove(target)
        recents = RecentHostsStore.shared.targets
        if case .recent(let picked) = picked, picked == target { self.picked = nil }
    }

    /// A recent's port, key and when it was last used.
    private func detail(for suggestion: Suggestion) -> String? {
        switch suggestion {
        case .alias:
            // The section's heading already says where it came from.
            return nil
        case .recent(let target):
            return Self.recentDetail(
                target, lastUsed: RecentHostsStore.shared.lastUsed(target), now: Date())
        }
    }

    /// "Port 2222 · id_ed25519 · 2 hours ago", leaving out what is unset.
    static func recentDetail(_ target: SSHTarget, lastUsed: Date?, now: Date) -> String {
        var parts: [String] = []
        if target.user == nil { parts.append(L10n.text("ui.connect.userFromConfig")) }
        if let port = target.port { parts.append(L10n.format("ui.connect.portValue", String(port))) }
        parts.append(target.identityFile.map { ($0 as NSString).lastPathComponent }
            ?? L10n.text("ui.connect.identityDefault"))
        if let lastUsed {
            parts.append(relativeTime.localizedString(for: lastUsed, relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }

    /// One for every row: the list is rebuilt on each keystroke.
    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let rowHeight: CGFloat = 36
    private static let headerHeight: CGFloat = 20

    /// Exactly what there is, up to about five rows; then it scrolls.
    private static func suggestionHeight(_ shown: (recents: [Suggestion], aliases: [Suggestion])) -> CGFloat {
        let rows = shown.recents.count + shown.aliases.count
        let headers = (shown.recents.isEmpty ? 0 : 1) + (shown.aliases.isEmpty ? 0 : 1)
        let content = CGFloat(rows) * (Self.rowHeight + 1) + CGFloat(headers) * (Self.headerHeight + 1) + 12
        return min(220, content)
    }
}
