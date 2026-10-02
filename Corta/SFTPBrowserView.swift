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

/// The SwiftUI half of the remote-file browser;
/// `SFTPBrowserModel` owns every piece of state this renders, and
/// `SFTPBrowserController` hosts it in an `NSHostingController` (the
/// `CommandHistoryController` pattern).
///
/// Layout: a path bar, the listing, the transfers section when there are
/// any, and a status line. Conflicts are a sheet, the new-directory and
/// rename prompts a small sheet with one field, delete an alert — each
/// driven by a piece of model state, so nothing here holds view-local
/// truth the tests cannot reach.
struct SFTPBrowserView: View {
    @Bindable var model: SFTPBrowserModel
    @State private var showDetails = false
    @State private var showTransfers = true
    @State private var transferContentHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            switch model.connectionState {
            case .needsHost:
                hostEntry
            case .connecting:
                connecting
            case .failed(let message):
                failure(message)
            case .connected:
                browser
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .toolbar { browserToolbar }
        .sheet(item: conflictBinding) { prompt in
            ConflictSheet(prompt: prompt, model: model)
        }
        .sheet(item: $model.textPrompt) { prompt in
            TextPromptSheet(prompt: prompt, model: model)
        }
        .alert(
            model.deleteConfirmation?.title ?? "",
            isPresented: deleteConfirmationPresented,
            presenting: model.deleteConfirmation
        ) { _ in
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("sftp.action.deleteConfirm"), role: .destructive) {
                model.confirmDelete()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// The first queued conflict prompt; dismissing the sheet without a
    /// choice (Escape) is a Skip, so a dismissed sheet never silently
    /// starts the transfer it was asking about.
    private var conflictBinding: Binding<SFTPBrowserModel.ConflictPrompt?> {
        Binding(
            get: { model.conflictPrompts.first },
            set: { newValue in
                if newValue == nil, let first = model.conflictPrompts.first {
                    model.resolveConflict(first.id, choice: .skip)
                }
            })
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { model.deleteConfirmation != nil },
            set: { if !$0 { model.deleteConfirmation = nil } })
    }

    // MARK: - Host entry (the `.remoteUnknown` launch)

    private var hostEntry: some View {
        VStack(spacing: 16) {
            Label("SFTP", systemImage: "folder.badge.gearshape")
                .font(.title2.weight(.semibold))
            // A reported host is a suggestion with its provenance stated;
            // an unknown one is a blank to fill in.
            Text(
                model.suggestedHost.map { L10n.format("sftp.host.suggestedMessage", $0) }
                    ?? L10n.text("ui.sftp.connectHelp")
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField(L10n.text("sftp.host.field"), text: $model.hostField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connect() }
                Button(L10n.text("sftp.host.connect")) { model.connect() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.hostField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: 380)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var connecting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.format("sftp.connecting", model.host ?? ""))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button(L10n.text("sftp.retry")) { model.connect() }
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - The browser

    private var browser: some View {
        VStack(spacing: 0) {
            listing
            if let listingError = model.listingError {
                Divider()
                Text(listingError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.transfers.isEmpty {
                Divider()
                transfersSection
            }
            Divider()
            statusBar
        }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        if model.connectionState == .connected {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.navigateUp() } label: { Label(L10n.text("sftp.action.up"), systemImage: "arrow.turn.left.up") }
                    .disabled(model.currentPath == "/" || model.isLoading)
                Button { model.refresh() } label: { Label(L10n.text("sftp.action.refresh"), systemImage: "arrow.clockwise") }
                    .disabled(model.isLoading)
            }
            ToolbarItem(placement: .principal) {
                TextField("/", text: $model.pathField)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 120, idealWidth: 280, maxWidth: 440)
                    .onSubmit { model.navigate(to: model.pathField) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestUpload() } label: { Label(L10n.text("sftp.action.upload"), systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon) }
                Button { model.requestDownload() } label: { Label(L10n.text("sftp.action.download"), systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                    .disabled(!model.canDownloadSelection)
                Menu {
                    Button(L10n.text("sftp.action.newDirectory")) { model.requestNewDirectory() }
                    Button(L10n.text("sftp.action.rename")) {
                        if let entry = model.selectedEntries.first { model.requestRename(entry) }
                    }.disabled(model.selectedEntries.count != 1)
                    Button(L10n.text("sftp.action.edit")) { model.requestEdit() }.disabled(!model.canEditSelection)
                    Button(L10n.text("sftp.action.delete"), role: .destructive) { model.requestDelete(model.selectedEntries) }
                        .disabled(model.selectedEntries.isEmpty)
                    Divider()
                    Toggle(L10n.text("ui.sftp.details"), isOn: $showDetails)
                    Toggle(L10n.text("sftp.transfers.title"), isOn: transferExpansion)
                } label: { Label(L10n.text("ui.common.more"), systemImage: "ellipsis").labelStyle(.titleAndIcon) }
            }
        }
    }

    private var listing: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn(L10n.text("sftp.column.name")) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.kind.symbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.navigateInto(entry) }
            }
            if showDetails {
                TableColumn(L10n.text("sftp.column.kind")) { entry in Text(entry.kind.title) }.width(60)
            }
            TableColumn(L10n.text("sftp.column.size")) { entry in
                Text(entry.size.map { SFTPBrowserModel.formattedByteCount($0) } ?? "—")
            }
            .width(80)
            if showDetails {
                TableColumn(L10n.text("sftp.column.permissions")) { entry in
                    Text(entry.permissions ?? "—").font(.system(size: 11, design: .monospaced))
                }.width(100)
            }
            TableColumn(L10n.text("sftp.column.modified")) { entry in
                Text(entry.modified.map { Self.modified.string(from: $0) } ?? "—")
            }
            .width(156)
        }
        .font(.system(size: 12))
        .alternatingRowBackgrounds(.disabled)
    }

    private static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let modified: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Action bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(L10n.format("ui.sftp.itemCount", model.entries.count))
            #if DEBUG
            if model.isDevelopmentPreview { Text(verbatim: "DEBUG").help(L10n.text("ui.demo.hint")) }
            #endif
            Spacer()
            volumeText
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var volumeText: some View {
        switch model.volumeStatus {
        case .unknown:
            EmptyView()
        case .unsupported:
            Text(L10n.text("sftp.volume.unavailable"))
                .foregroundStyle(.secondary)
        case .available(let free, _):
            Text(L10n.format(
                "sftp.volume.free",
                SFTPBrowserModel.formattedByteCount(free)))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transfers

    private var transferExpansion: Binding<Bool> {
        Binding(get: { showTransfers }, set: { expanded in
            withAnimation(SystemAccessibility.reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                showTransfers = expanded
            }
        })
    }

    private var transfersSection: some View {
        DisclosureGroup(L10n.text("sftp.transfers.title"), isExpanded: transferExpansion) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.transfers) { transfer in TransferRow(transfer: transfer, model: model) }
                }
                .padding(.top, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - transferContentHeight) > 0.5 { transferContentHeight = height }
                }
            }
            .frame(height: min(150, max(1, transferContentHeight)))
        }.padding(16).font(.system(size: 12))
    }

    private struct TransferRow: View {
        let transfer: SFTPBrowserModel.Transfer
        let model: SFTPBrowserModel

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: transfer.isUpload ? "arrow.up.doc" : "arrow.down.doc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name)
                        .help(transfer.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if case .active = transfer.state {
                        stateView
                    } else {
                        HStack(alignment: .center, spacing: 12) {
                            stateView.frame(maxWidth: .infinity, alignment: .leading)
                            actions.controlSize(.regular)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        private var stateView: some View {
            switch transfer.state {
            case .queued:
                Text(L10n.text("sftp.transfer.queued"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .active(let completed, let total):
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if let total, total > 0 {
                                ProgressView(value: Double(completed), total: Double(total))
                                    .progressViewStyle(.linear)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }.frame(maxWidth: .infinity)
                        actions.controlSize(.regular)
                    }
                    // A directory transfer says where in the tree it is.
                    if transfer.isDirectory, transfer.filesTotal > 0 {
                        Text(
                            L10n.format(
                                "sftp.transfer.files", transfer.filesCompleted, transfer.filesTotal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            case .cancelling:
                Text(L10n.text("sftp.transfer.cancelling"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .done(let bytes):
                Text(
                    transfer.isDirectory
                        ? L10n.format(
                            "sftp.transfer.doneDirectory", transfer.filesTotal,
                            SFTPBrowserModel.formattedByteCount(bytes))
                        : L10n.format(
                            "sftp.transfer.doneBytes",
                            SFTPBrowserModel.formattedByteCount(bytes))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .cancelled(let partialKept):
                Text(
                    partialKept
                        ? L10n.text("sftp.transfer.cancelledPartial")
                        : L10n.text("sftp.transfer.cancelled")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .skipped:
                Text(L10n.text("sftp.transfer.skipped"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message, _):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }

        @ViewBuilder
        private var actions: some View {
            switch transfer.state {
            case .queued, .active:
                Button(L10n.text("common.cancel")) { model.cancelTransfer(transfer.id) }
                    .font(.system(size: 12))
            case .failed(_, let retryable) where retryable:
                Button(L10n.text("sftp.retry")) { model.retryTransfer(transfer.id) }
                    .font(.system(size: 12))
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Conflict sheet

    private struct ConflictSheet: View {
        let prompt: SFTPBrowserModel.ConflictPrompt
        let model: SFTPBrowserModel

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("sftp.conflict.title"))
                    .font(.headline)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button(L10n.text("sftp.conflict.skip")) {
                        model.resolveConflict(prompt.id, choice: .skip)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("sftp.conflict.keepBoth")) {
                        model.resolveConflict(prompt.id, choice: .keepBoth)
                    }
                    if prompt.canResume {
                        Button(L10n.text("sftp.conflict.resume")) {
                            model.resolveConflict(prompt.id, choice: .resume)
                        }
                    }
                    Button(L10n.text("sftp.conflict.overwrite")) {
                        model.resolveConflict(prompt.id, choice: .overwrite)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }

        private var message: String {
            let key =
                prompt.partialOnly
                ? "sftp.conflict.message.partial" : "sftp.conflict.message.destination"
            return L10n.format(
                key, prompt.path, prompt.destinationDescription, prompt.sourceDescription)
        }
    }

    // MARK: - New directory / rename sheet

    private struct TextPromptSheet: View {
        let prompt: SFTPBrowserModel.TextPrompt
        let model: SFTPBrowserModel
        @State private var text: String

        init(prompt: SFTPBrowserModel.TextPrompt, model: SFTPBrowserModel) {
            self.prompt = prompt
            self.model = model
            _text = State(initialValue: prompt.initialText)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.title)
                    .font(.headline)
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitTextPrompt(text) }
                HStack {
                    Spacer()
                    Button(L10n.text("common.cancel")) { model.textPrompt = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(prompt.title) { model.commitTextPrompt(text) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 320)
        }
    }
}
