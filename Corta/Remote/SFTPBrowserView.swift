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

/// The SwiftUI half of the remote-file browser;
/// `SFTPBrowserModel` owns every piece of state this renders, and
/// `SFTPBrowserController` hosts it in an `NSHostingController` (the
/// `CommandHistoryController` pattern).
///
/// Layout, the way Finder's is: Back and Forward, a breadcrumb path, and
/// the actions in the toolbar; the listing fills the window; transfers live
/// in a toolbar popover, as Safari's downloads do, so they take no room
/// while nothing is moving; a status line at the foot. Conflicts are a
/// sheet, the new-directory and rename prompts a small sheet with one
/// field, delete an alert — each driven by a piece of model state, so
/// nothing here holds view-local truth the tests cannot reach.
struct SFTPBrowserView: View {
    @Bindable var model: SFTPBrowserModel
    @State private var showDetails = false
    @State private var showTransfers = false
    @State private var editingPath = false
    @State private var sortOrder = [KeyPathComparator(\SFTPBrowserModel.Entry.name)]
    @State private var showFailureDetails = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.connectionState {
            case .needsHost:
                hostEntry(error: nil)
            case .connecting:
                connecting
            case .failed(let message):
                if let failure = model.connectFailure {
                    failurePanel(failure)
                } else {
                    hostEntry(error: message)
                }
            case .connected:
                browser
            }
        }
        .frame(minWidth: 720, minHeight: 360)
        .toolbar { browserToolbar }
        // A new transfer opens the list, the way a new download opens
        // Safari's: the user sees it start without having to look for it.
        .onChange(of: model.transfers.count) { old, new in
            if new > old { showTransfers = true }
        }
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

    // MARK: - Host entry, connecting, failure

    /// The host step — a `.remoteUnknown` launch, a reported host waiting
    /// for consent, or a failure to correct and retry — in the same form the
    /// connect sheet uses. A reported host says where its name came from.
    private func hostEntry(error: String?) -> some View {
        ScrollView {
            RemoteConnectForm(
                mode: .sftp, fields: $model.fields,
                notice: model.suggestedHost.map { L10n.format("sftp.host.suggestedMessage", $0) },
                error: error,
                onConnect: { model.isFailed ? model.retry() : model.connect() })
                .frame(maxWidth: 500)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// ssh's own words, behind a Details disclosure, selectable.
    @ViewBuilder
    private func failureDetails(_ details: String) -> some View {
        Button {
            showFailureDetails.toggle()
        } label: {
            Label(L10n.text("panel.details"),
                  systemImage: showFailureDetails ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sftp-failure-details")
        if showFailureDetails {
            Text(details)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }

    /// A connection that failed, said the way a pane says it stopped
    /// (`PaneStatusPanel`): the kind of failure in a sentence, ssh's own
    /// words behind Details, and the two ways on — the fields again, or the
    /// same connection again.
    private func failurePanel(_ failure: SFTPBrowserModel.ConnectFailure) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 6) {
                    Image(systemName: failure.symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                    Text(failure.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(failure.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    failureDetails(failure.details)
                    HStack(spacing: 10) {
                        Button(L10n.text("sftp.failure.edit")) { model.cancelConnect() }
                        Button(L10n.text("failure.button.retry")) { model.retry() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.large)
                    .padding(.top, 10)
                }
                .frame(width: 340)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                // `PaneStatusPanel`'s card: the same edge and shadow.
                .background(.background, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
                .accessibilityElement(children: .contain)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.windowBackground)
        .onChange(of: failure) { showFailureDetails = false }
    }

    /// Progress with a way out: a host that never answers is cancelled
    /// back to the host field, not a window that can only be closed.
    private var connecting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.format("sftp.connecting", model.displayHost ?? ""))
                .foregroundStyle(.secondary)
            Button(L10n.text("common.cancel")) { model.cancelConnect() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - The browser

extension SFTPBrowserView {

    private var browser: some View {
        VStack(spacing: 0) {
            listing
            if let listingError = model.listingError {
                Divider()
                Label(listingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            statusBar
        }
        .background { keyboardShortcuts }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        if model.connectionState == .connected {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.navigateBack() } label: {
                    Label(L10n.text("sftp.action.back"), systemImage: "chevron.left")
                }
                .help(L10n.text("sftp.action.back"))
                .disabled(!model.canGoBack || model.isLoading)
                Button { model.navigateForward() } label: {
                    Label(L10n.text("sftp.action.forward"), systemImage: "chevron.right")
                }
                .help(L10n.text("sftp.action.forward"))
                .disabled(!model.canGoForward || model.isLoading)
            }
            ToolbarItem(placement: .principal) {
                SFTPPathBar(model: model, editing: $editingPath)
            }
            // Icons only, the way a toolbar's items are; the labels stay for
            // VoiceOver and the tooltips. Upload and download are arrows into
            // and out of the server — the box-and-arrow glyph means Share.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestUpload() } label: {
                    Label(L10n.text("sftp.action.upload"), systemImage: "arrow.up.circle")
                }
                .help(L10n.text("sftp.action.upload"))
                Button { model.requestDownload() } label: {
                    Label(L10n.text("sftp.action.download"), systemImage: "arrow.down.circle")
                }
                .help(L10n.text("sftp.action.download"))
                .disabled(!model.canDownloadSelection)
            }
            if !model.transfers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    SFTPTransfersButton(model: model, isPresented: $showTransfers)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                moreMenu
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.text("sftp.action.newDirectory")) { model.requestNewDirectory() }
            Button(L10n.text("sftp.action.rename")) {
                if let entry = model.selectedEntries.first { model.requestRename(entry) }
            }.disabled(model.selectedEntries.count != 1)
            Button(L10n.text("sftp.action.edit")) { model.requestEdit() }.disabled(!model.canEditSelection)
            Button(L10n.text("sftp.action.delete"), role: .destructive) { model.requestDelete(model.selectedEntries) }
                .disabled(model.selectedEntries.isEmpty)
            Divider()
            Button(L10n.text("sftp.action.up")) { model.navigateUp() }
                .disabled(model.currentPath == "/")
            Button(L10n.text("sftp.action.refresh")) { model.refresh() }
            Button(L10n.text("sftp.action.goToFolder")) { editingPath = true }
            Divider()
            Toggle(L10n.text("sftp.action.showHidden"), isOn: $model.showsHiddenFiles)
            Toggle(L10n.text("ui.sftp.details"), isOn: $showDetails)
        } label: {
            Label(L10n.text("ui.common.more"), systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help(L10n.text("ui.common.more"))
    }

    /// Finder's keys for the same actions, live while the listing is shown.
    /// A menu inside the toolbar does not register its items' shortcuts, so
    /// they are held by invisible buttons here.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { model.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            Button("") { model.navigateForward() }.keyboardShortcut("]", modifiers: .command)
            Button("") { model.navigateUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
            Button("") { editingPath = true }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") { model.requestNewDirectory() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { model.showsHiddenFiles.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Listing

    private var listing: some View {
        Table(of: SFTPBrowserModel.Entry.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn(L10n.text("sftp.column.name"), value: \.name) { entry in
                HStack(spacing: 6) {
                    // A fixed slot: a folder glyph is wider than a document's,
                    // and the names started at two different x positions.
                    Image(systemName: entry.kind.symbolName)
                        .foregroundStyle(entry.kind == .directory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(entry.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if showDetails {
                TableColumn(L10n.text("sftp.column.kind")) { entry in Text(entry.kind.title) }.width(70)
            }
            // Numbers line up on the right, as Finder sets them.
            TableColumn(L10n.text("sftp.column.size"), value: \.sortSize) { entry in
                // A folder's size is its directory entry's, which says nothing
                // about what it holds; Finder shows "--" there too.
                Text(
                    entry.kind == .directory
                        ? "--" : entry.size.map { SFTPBrowserModel.formattedByteCount($0) } ?? "--")
                    .monospacedDigit()
                    .foregroundStyle(entry.kind == .directory ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 120)
            if showDetails {
                TableColumn(L10n.text("sftp.column.permissions")) { entry in
                    Text(entry.permissions ?? "--").font(.system(size: 11, design: .monospaced))
                }.width(100)
            }
            TableColumn(L10n.text("sftp.column.modified"), value: \.sortModified) { entry in
                Text(entry.modified.map { Self.modified.string(from: $0) } ?? "--")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 240)
        } rows: {
            ForEach(model.entries) { entry in
                if entry.kind == .file {
                    // Dragged to Finder, a file is downloaded where it lands.
                    TableRow(entry)
                        .itemProvider { model.dragItem(for: entry).itemProvider() }
                } else {
                    TableRow(entry)
                }
            }
        }
        .alternatingRowBackgrounds(.enabled)
        // Files from Finder: into the folder row they land on, or the
        // folder shown (`SFTPDropTarget`).
        .overlay { SFTPDropTarget(model: model) }
        // Double-click or Return opens a row anywhere in it, not only on its
        // name; the menu is the same actions the toolbar's ⋯ holds, on what
        // was clicked.
        .contextMenu(forSelectionType: SFTPBrowserModel.Entry.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            guard ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) })
            else { return }
            model.navigateInto(entry)
        }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            switch first.keyPath {
            case \SFTPBrowserModel.Entry.sortSize: model.sortColumn = .size
            case \SFTPBrowserModel.Entry.sortModified: model.sortColumn = .modified
            default: model.sortColumn = .name
            }
            model.sortAscending = first.order == .forward
        }
    }

    /// The row menu acts on the clicked rows: right-clicking outside the
    /// selection selects what was clicked first, as Finder does.
    @ViewBuilder
    private func rowMenu(for ids: Set<SFTPBrowserModel.Entry.ID>) -> some View {
        let entries = model.entries.filter { ids.contains($0.id) }
        if entries.isEmpty {
            Button(L10n.text("sftp.action.newDirectory")) { model.requestNewDirectory() }
            Button(L10n.text("sftp.action.upload")) { model.requestUpload() }
            Button(L10n.text("sftp.action.refresh")) { model.refresh() }
        } else {
            if entries.count == 1, let entry = entries.first, entry.kind == .directory {
                Button(L10n.text("sftp.action.open")) { model.navigateInto(entry) }
                Divider()
            }
            Button(L10n.text("sftp.action.download")) {
                model.selection = ids
                model.requestDownload()
            }
            .disabled(!entries.contains { $0.kind == .file || $0.kind == .directory })
            Button(L10n.text("sftp.action.edit")) {
                model.selection = ids
                model.requestEdit()
            }
            .disabled(entries.count != 1 || entries.first?.kind != .file)
            Button(L10n.text("sftp.action.rename")) {
                if let entry = entries.first { model.requestRename(entry) }
            }
            .disabled(entries.count != 1)
            Divider()
            Button(L10n.text("sftp.action.delete"), role: .destructive) {
                model.requestDelete(entries)
            }
        }
    }

    /// Finder's dates: "Today at 20:00", "Yesterday at 09:12", then the date.
    private static let modified: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // MARK: - Status line

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(L10n.format("ui.sftp.itemCount", model.entries.count))
            if model.hiddenEntryCount > 0 {
                Text(verbatim: "·")
                Text(L10n.format("sftp.status.hidden", model.hiddenEntryCount))
            }
            #if DEBUG
            if model.isDevelopmentPreview { Text(verbatim: "· DEBUG").help(L10n.text("ui.demo.hint")) }
            #endif
            Spacer()
            volumeText
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var volumeText: some View {
        switch model.volumeStatus {
        case .unknown:
            EmptyView()
        case .unsupported:
            Text(L10n.text("sftp.volume.unavailable"))
        case .available(let free, _):
            // Whose space it is, said: the local disk is not the question here.
            Text(L10n.format("sftp.volume.freeRemote", SFTPBrowserModel.formattedByteCount(free)))
        }
    }
}
