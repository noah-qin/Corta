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
import CortaSFTP
import CortaTerminal
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        VStack(spacing: 0) {
            switch model.connectionState {
            case .needsHost:
                hostEntry(error: nil)
            case .connecting:
                connecting
            case .failed(let message):
                hostEntry(error: message)
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
                mode: .sftp, host: $model.hostField,
                notice: model.suggestedHost.map { L10n.format("sftp.host.suggestedMessage", $0) },
                error: error,
                onConnect: { model.isFailed ? model.retry() : model.connect() })
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Progress with a way out: a host that never answers is cancelled
    /// back to the host field, not a window that can only be closed.
    private var connecting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.format("sftp.connecting", model.host ?? ""))
                .foregroundStyle(.secondary)
            Button(L10n.text("common.cancel")) { model.cancelConnect() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The browser

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
                if entry.kind == .directory {
                    // Dropped on a folder row, files go into that folder.
                    TableRow(entry)
                        .dropDestination(for: URL.self) { urls in
                            model.upload(
                                urls, into: SFTPBrowserModel.joinPath(model.currentPath, entry.name))
                        }
                } else if entry.kind == .file {
                    // Dragged to Finder, a file is downloaded where it lands.
                    TableRow(entry)
                        .draggable(SFTPDragItem(name: SFTPBrowserModel.localFileName(entry.name)) { [model] in
                            try await model.exportForDrag(entry)
                        })
                } else {
                    TableRow(entry)
                }
            }
        }
        .alternatingRowBackgrounds(.enabled)
        // Dropped anywhere else on the listing, into the current directory.
        .dropDestination(for: URL.self) { urls, _ in model.upload(urls) }
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

// MARK: - Path bar

/// The current directory as a breadcrumb: each component goes there on a
/// click. Clicking the bar's free space — or Go to Folder… (⇧⌘G) — turns it
/// into a field for typing a path; Return goes, Escape puts the crumbs back.
/// A deep path folds its middle into "…" rather than overflowing.
struct SFTPPathBar: View {
    @Bindable var model: SFTPBrowserModel
    @Binding var editing: Bool

    nonisolated struct Crumb: Identifiable {
        let title: String
        let path: String
        var id: String { path }
    }

    private var crumbs: [Crumb] {
        Self.breadcrumbs(for: model.currentPath)
    }

    /// Build only the visible ancestors. Retaining every prefix of a peer
    /// path before folding made a frame-sized path consume quadratic memory.
    /// At most root, ellipsis and six trailing components are retained.
    nonisolated static func breadcrumbs(for path: String, keepingLast count: Int = 6) -> [Crumb] {
        let components = path.split(separator: "/")
        let kept = min(6, max(1, count))
        var result = [Crumb(title: "/", path: "/")]
        if components.count > kept + 1 {
            let ancestor = components[components.count - kept - 1]
            result.append(Crumb(title: "…", path: String(path[..<ancestor.endIndex])))
            for component in components.suffix(kept) {
                result.append(Crumb(title: String(component), path: String(path[..<component.endIndex])))
            }
        } else {
            for component in components {
                result.append(Crumb(title: String(component), path: String(path[..<component.endIndex])))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if editing {
                PathEntryField(
                    text: $model.pathField,
                    onSubmit: {
                        model.navigate(to: model.pathField)
                        editing = false
                    },
                    onCancel: stopEditing)
                .onAppear { model.pathField = model.currentPath }
            } else {
                ViewThatFits(in: .horizontal) {
                    trail(crumbs)
                    trail(folded(keepingLast: 2))
                    trail(folded(keepingLast: 1))
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 340, minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("sftp.path.label"))
    }

    private func stopEditing() {
        editing = false
        model.pathField = model.currentPath
    }

    /// Root, an ellipsis standing for the middle, and the last few.
    private func folded(keepingLast count: Int) -> [Crumb] {
        Self.breadcrumbs(for: model.currentPath, keepingLast: count)
    }

    private func trail(_ items: [Crumb]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, crumb in
                if index > 1 || (index == 1 && items[0].path != "/") {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                let isLast = index == items.count - 1
                Button(crumb.title) { model.navigate(to: crumb.path) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .disabled(isLast)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The path bar's field. AppKit, because focus asked for through SwiftUI
/// did not reach a field inside a toolbar item: this one takes first
/// responder as it joins the window, goes on Return, and gives up on
/// Escape or on losing focus.
private struct PathEntryField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "/"
        field.setAccessibilityLabel(L10n.text("sftp.path.label"))
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathEntryField
        private var finished = false
        init(_ parent: PathEntryField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finished = true
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }
    }

    private final class FocusingTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}

// MARK: - Transfers

/// The toolbar's transfers button: a ring for the bytes still to move,
/// and the list in a popover.
struct SFTPTransfersButton: View {
    let model: SFTPBrowserModel
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label {
                Text(L10n.text("sftp.transfers.title"))
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
                    .imageScale(.small)
                    .overlay {
                        if let progress = model.transferQueue.overallProgress {
                            // A faint full track, then the bytes moved so far.
                            ZStack {
                                Circle().stroke(.quaternary, lineWidth: 2)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 22, height: 22)
                        }
                    }
            }
        }
        .help(L10n.text("sftp.transfers.title"))
        .accessibilityValue(
            model.transferQueue.activeCount > 0
                ? L10n.format("sftp.transfers.active", model.transferQueue.activeCount) : "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SFTPTransfersList(model: model)
        }
    }
}

/// The popover: every transfer, newest last, and Clear for the finished.
struct SFTPTransfersList: View {
    let model: SFTPBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("sftp.transfers.title")).font(.headline)
                Spacer()
                Button(L10n.text("sftp.transfers.clear")) { model.transferQueue.clearFinished() }
                    .disabled(!model.transfers.contains(where: \.isFinished))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.transfers) { transfer in
                        TransferRow(transfer: transfer, model: model)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 380)
    }
}

private struct TransferRow: View {
    let transfer: SFTPBrowserModel.Transfer
    let model: SFTPBrowserModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: transfer.isUpload ? "arrow.up.doc" : "arrow.down.doc")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .help(transfer.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .active(let completed, let total) = transfer.state {
                    Group {
                        if let total, total > 0 {
                            ProgressView(value: Double(min(completed, total)), total: Double(total))
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch transfer.state {
        case .queued:
            Text(L10n.text("sftp.transfer.queued")).font(.caption).foregroundStyle(.secondary)
        case .active(let completed, let total):
            Text(
                SFTPBrowserModel.progressDetail(
                    completed: completed, total: total, bytesPerSecond: transfer.bytesPerSecond,
                    remainingSeconds: transfer.remainingSeconds,
                    files: transfer.isDirectory && transfer.filesTotal > 0
                        ? (transfer.filesCompleted, transfer.filesTotal) : nil)
            )
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        case .cancelling:
            Text(L10n.text("sftp.transfer.cancelling")).font(.caption).foregroundStyle(.secondary)
        case .done(let bytes):
            Text(
                transfer.isDirectory
                    ? L10n.format(
                        "sftp.transfer.doneDirectory", transfer.filesTotal,
                        SFTPBrowserModel.formattedByteCount(bytes))
                    : L10n.format(
                        "sftp.transfer.doneBytes", SFTPBrowserModel.formattedByteCount(bytes))
            )
            .font(.caption).foregroundStyle(.secondary)
        case .cancelled(let partialKept):
            Text(
                partialKept
                    ? L10n.text("sftp.transfer.cancelledPartial") : L10n.text("sftp.transfer.cancelled")
            )
            .font(.caption).foregroundStyle(.secondary)
        case .skipped:
            Text(L10n.text("sftp.transfer.skipped")).font(.caption).foregroundStyle(.secondary)
        case .failed(let message, _):
            // A symbol and the words, never the colour alone.
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
                .textSelection(.enabled)
        }
    }

    /// One action per state, as an icon button with its name for VoiceOver:
    /// stop a running one, retry a retryable failure, show a finished
    /// download in Finder.
    @ViewBuilder
    private var action: some View {
        switch transfer.state {
        case .queued, .active:
            iconButton("xmark.circle.fill", L10n.text("common.cancel")) {
                model.cancelTransfer(transfer.id)
            }
        case .failed(_, let retryable) where retryable:
            iconButton("arrow.clockwise.circle.fill", L10n.text("sftp.retry")) {
                model.retryTransfer(transfer.id)
            }
        case .done where !transfer.isUpload
            && FileManager.default.fileExists(atPath: transfer.localURL.path):
            iconButton("magnifyingglass.circle.fill", L10n.text("sftp.transfer.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([transfer.localURL])
            }
        default:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Drag to Finder

/// One remote file as a drag: Finder asks for the file when it is dropped,
/// and the export downloads it (through the transfer queue, with a progress
/// row) into a private staging folder the system then copies from.
struct SFTPDragItem: Transferable {
    let name: String
    let export: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.export(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.name }
    }
}
