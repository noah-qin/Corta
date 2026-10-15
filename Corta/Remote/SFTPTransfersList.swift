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
import UniformTypeIdentifiers

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
