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

import SwiftUI

/// The SwiftUI half of the command history window;
/// `CommandHistoryModel` is the other half, and `CommandHistoryController`
/// only hosts this view in an `NSHostingController` and forwards `show(for:)`.
struct CommandHistoryView: View {
    @Bindable var model: CommandHistoryModel

    /// The window's content size, fixed: the controller builds the window
    /// from it.
    static let size = CGSize(width: 700, height: 500)

    var body: some View {
        let rows = model.rows
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                filterRow
                results(rows)
                HStack {
                    if model.noPaneMessage == nil {
                        Text(L10n.format("commandHistory.count", rows.count))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("commandHistory.clear")) { model.clearHistory() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(model.noPaneMessage != nil)
                }
            }
        }
        .task(id: model.projectLookupPaths) { await model.resolveProjectRoots() }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// A capsule of glass, as the connect sheet's host field.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.text("commandHistory.searchPlaceholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .accessibilityLabel(L10n.text("commandHistory.searchLabel"))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// Where it ran, how it ended, which machine: large capsules, each its
    /// own width.
    private var filterRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $model.directoryOnly) {
                Label(L10n.text("commandHistory.thisDirectory"), systemImage: "folder")
            }
            Toggle(isOn: $model.projectOnly) {
                Label(L10n.text("commandHistory.thisProject"), systemImage: "shippingbox")
            }
            Picker(selection: $model.exitFilter) {
                ForEach(CommandHistoryModel.ExitFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            } label: { EmptyView() }
            .labelsHidden()
            // "Which machine did it run on", alongside the existing
            // where-did-it-run filters. The hosts on offer are the ones this
            // pane's records actually name (`CommandHistoryModel.knownHosts`).
            Picker(selection: $model.hostScope) {
                Text(L10n.text("commandHistory.hostAny"))
                    .tag(CommandHistoryModel.HostScope.any)
                Text(L10n.text("commandHistory.hostLocal"))
                    .tag(CommandHistoryModel.HostScope.local)
                ForEach(model.knownHosts, id: \.self) { host in
                    Text(host).tag(CommandHistoryModel.HostScope.host(host))
                }
            } label: { EmptyView() }
            .labelsHidden()
            Spacer(minLength: 0)
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.large)
    }

    /// The records in a card of glass, or what there is instead of them.
    private func results(_ rows: [CommandHistoryModel.Row]) -> some View {
        Group {
            if let message = model.noPaneMessage {
                ContentUnavailableView(message, systemImage: "terminal")
            } else if rows.isEmpty {
                ContentUnavailableView(
                    L10n.text("commandHistory.empty"), systemImage: "clock.arrow.circlepath")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            CommandHistoryRowView(row: row, model: model)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct CommandHistoryRowView: View {
    let row: CommandHistoryModel.Row
    let model: CommandHistoryModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.statusSymbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(row.timestamp)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // The command itself, monospaced: what the row is *about*. A
            // record whose prompt line has scrolled away says so rather
            // than showing a blank — the timestamp and status still stand.
            Text(row.commandText ?? L10n.text("commandHistory.textGone"))
                .font(Font(CommandHistoryModel.commandFont()))
                .foregroundStyle(row.commandText == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Run compares the command's width with this one: narrower
                // than the text, the tail was cut.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    model.noteShownCommandWidth(width, id: row.id)
                }
                .help(row.commandText ?? "")
            Text(row.directoryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.directoryTooltip ?? "")
            Spacer(minLength: 8)
            Group {
                Button(L10n.text("commandHistory.find")) { model.find(id: row.id) }
                Button(L10n.text("commandHistory.fill")) { model.fill(id: row.id) }
                    .disabled(!row.canFillOrRun)
                Button(L10n.text("commandHistory.run")) { model.run(id: row.id, shown: row.commandText) }
                    .disabled(!row.canFillOrRun)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
