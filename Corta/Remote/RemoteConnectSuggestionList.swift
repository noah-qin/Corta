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

/// The hosts the connect form suggests — recent connections and
/// `~/.ssh/config` aliases — in a card of glass: a click fills the fields
/// and highlights the row, a double-click connects; a recent host is
/// forgotten from its ✕ or its menu. Exactly what there is, up to about
/// five rows; then it scrolls.
struct RemoteConnectSuggestionList: View {
    typealias Suggestion = RemoteConnectForm.Suggestion

    let recents: [Suggestion]
    let aliases: [Suggestion]
    /// Git hosts left out of the list, named in the aliases' heading.
    let hiddenGitHosts: [String]
    /// The suggestion the fields still hold, highlighted.
    let picked: Suggestion?
    let onPick: (Suggestion) -> Void
    let onConnect: () -> Void
    let onForget: (SSHTarget) -> Void

    @State private var hovered: Suggestion?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                suggestionSection(L10n.text("ui.connect.recent"), recents, symbol: "clock")
                suggestionSection(
                    L10n.text("ui.connect.sshConfig"), aliases, symbol: "doc.text",
                    trailing: hiddenGitHosts.isEmpty
                        ? nil : L10n.format("ui.connect.gitHostsHidden", hiddenGitHosts.joined(separator: ", ")))
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: RemoteConnectForm.cardRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: RemoteConnectForm.cardRadius))
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
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight, alignment: .bottom)
            ForEach(suggestions, id: \.self) { suggestion in
                suggestionRow(suggestion, symbol: symbol)
            }
        }
    }

    private func suggestionRow(_ suggestion: Suggestion, symbol: String) -> some View {
        let isPicked = picked == suggestion
        let isHovered = hovered == suggestion
        return Button {
            onPick(suggestion)
        } label: {
            suggestionLabel(suggestion, symbol: symbol, isPicked: isPicked, isHovered: isHovered)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(
                isPicked ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                    : isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .onHover { inside in
            if inside { hovered = suggestion } else if isHovered { hovered = nil }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onPick(suggestion)
            onConnect()
        })
        .contextMenu {
            if case .recent(let target) = suggestion {
                Button(L10n.text("ui.connect.removeRecent")) { onForget(target) }
            }
        }
    }

    /// The row's symbol, name and detail, and at its end either Forget (a
    /// hovered recent host) or the picked mark.
    private func suggestionLabel(
        _ suggestion: Suggestion, symbol: String, isPicked: Bool, isHovered: Bool
    ) -> some View {
        let detail = detail(for: suggestion)
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.name).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if case .recent(let target) = suggestion, isHovered {
                Button {
                    onForget(target)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("ui.connect.removeRecent"))
                .accessibilityLabel(L10n.text("ui.connect.removeRecent"))
            } else if isPicked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
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

    private static let rowHeight: CGFloat = 42
    private static let headerHeight: CGFloat = 22

    private var height: CGFloat {
        let rows = recents.count + aliases.count
        let headers = (recents.isEmpty ? 0 : 1) + (aliases.isEmpty ? 0 : 1)
        let content = CGFloat(rows) * (Self.rowHeight + 2) + CGFloat(headers) * (Self.headerHeight + 2) + 12
        return min(240, content)
    }
}
