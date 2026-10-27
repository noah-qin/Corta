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
        return GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let modeSelection {
                    Picker(L10n.text("ui.connect.modeLabel"), selection: modeSelection) {
                        Label(L10n.text("ui.connect.mode.terminal"), systemImage: "terminal")
                            .tag(RemoteConnectMode.ssh)
                        Label(L10n.text("ui.connect.mode.files"), systemImage: "folder")
                            .tag(RemoteConnectMode.sftp)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("connect-mode")
                }
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardRadius))
                }
                if let paneFiles {
                    paneFilesRow(paneFiles)
                }
                hostField
                advanced
                if let error {
                    // Said in words with a symbol, never by colour alone.
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                }
                if !shown.recents.isEmpty || !shown.aliases.isEmpty {
                    RemoteConnectSuggestionList(
                        recents: shown.recents, aliases: shown.aliases, hiddenGitHosts: hiddenGitHosts,
                        picked: pickedIsCurrent ? picked : nil, onPick: pick, onConnect: onConnect,
                        onForget: forget)
                }
                HStack(spacing: 10) {
                    Spacer()
                    if let onCancel {
                        Button(action: onCancel) {
                            Text(L10n.text("common.cancel")).frame(minWidth: 72)
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    }
                    Button(action: onConnect) {
                        Text(L10n.text("sftp.host.connect")).frame(minWidth: 72)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    // Empty in Files, Return opens the focused pane's host's.
                    .disabled(fields.isEmpty && !(paneFiles != nil && mode == .sftp))
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(24)
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
            let found = await SSHConfigHosts.loadSuggestions()
            guard !Task.isCancelled else { return }
            aliases = found.hosts
            hiddenGitHosts = found.hiddenGitHosts
        }
    }

    /// The task beside its symbol, and what the connection relies on.
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: modeSelection == nil ? mode.symbol : "network")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(modeSelection == nil ? mode.title : L10n.text("ui.connect.title"))
                    .font(.title3.weight(.semibold))
                Text(help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The host, in a capsule of glass that rings with the accent colour
    /// while it has focus.
    private var hostField: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.text("ui.ssh.host"), text: $fields.host,
                      prompt: Text(L10n.text("ui.connect.hostPrompt")))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.title3)
                .focused($hostFocused)
                .onSubmit(onConnect)
                // ↓ and ↑ walk the suggestions from the field, the way an
                // address bar's do; Return then connects to the one picked.
                .onKeyPress(.downArrow) { stepSuggestion(by: 1) }
                .onKeyPress(.upArrow) { stepSuggestion(by: -1) }
                .accessibilityLabel(L10n.text("ui.ssh.host"))
                .accessibilityIdentifier("connect-host")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(hostFocused ? 0.7 : 0), lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: hostFocused)
        }
        .contentShape(.capsule)
        .onTapGesture { hostFocused = true }
    }

    /// The focused pane's host, one Return away when the field is empty.
    private func paneFilesRow(_ paneFiles: RemoteConnectPaneFiles) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.tint)
                .frame(width: 20)
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
            .buttonStyle(.glass)
            .accessibilityIdentifier("connect-pane-files")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardRadius))
    }

}

// MARK: - Advanced: user, port and key

extension RemoteConnectForm {
    /// User, port and key: rarely changed, so behind a row that says what
    /// they hold, opening in the same card.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(L10n.text("ui.connect.advanced"))
                    Spacer(minLength: 12)
                    if !showsAdvanced {
                        Text(advancedSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvanced ? "" : advancedSummary)
            .accessibilityIdentifier("connect-advanced")
            if showsAdvanced {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(L10n.text("ui.connect.user")).gridColumnAlignment(.trailing)
                        advancedField(
                            L10n.text("ui.connect.user"), text: $fields.user,
                            prompt: L10n.text("ui.connect.fromConfig"))
                            .accessibilityIdentifier("connect-user")
                    }
                    GridRow {
                        Text(L10n.text("ui.ssh.port"))
                        advancedField(L10n.text("ui.ssh.port"), text: $fields.port, prompt: "22")
                            .frame(width: 100)
                            .help(L10n.text("ui.ssh.portDefault"))
                            .accessibilityIdentifier("connect-port")
                    }
                    GridRow {
                        Text(L10n.text("ui.connect.identity"))
                        identityRow
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardRadius))
    }

    /// A small capsule field inside the Advanced card.
    private func advancedField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        TextField(label, text: text, prompt: Text(verbatim: prompt))
            .textFieldStyle(.plain)
            .labelsHidden()
            .foregroundStyle(.primary)
            .onSubmit(onConnect)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.fill.tertiary, in: .capsule)
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
            Spacer(minLength: 4)
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
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
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
}

// MARK: - Suggestions

extension RemoteConnectForm {
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

    private func forget(_ target: SSHTarget) {
        RecentHostsStore.shared.remove(target)
        recents = RecentHostsStore.shared.targets
        if case .recent(let picked) = picked, picked == target { self.picked = nil }
    }

    static let cardRadius: CGFloat = 18
}
