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

/// Files dropped from Finder on the browser's listing upload — into the
/// folder row they land on, or else the folder shown — and while they are
/// dragged the listing says where they will go.
///
/// AppKit, laid over the SwiftUI `Table`: `.dropDestination` on the table
/// and on its rows never received a drop from Finder. The view lets every
/// click through (`hitTest`), so selection, menus and dragging rows out
/// work as before; only a drag from outside Corta is taken.
struct SFTPDropTarget: NSViewRepresentable {
    let model: SFTPBrowserModel

    func makeNSView(context: Context) -> SFTPDropTargetView {
        let view = SFTPDropTargetView()
        view.model = model
        return view
    }

    func updateNSView(_ view: SFTPDropTargetView, context: Context) {
        view.model = model
    }
}

/// Where a drop goes, from the row it is over; pure, for tests.
nonisolated enum SFTPDropDestination: Equatable {
    /// The folder shown.
    case current(path: String)
    /// A folder row: the folder's path and its name.
    case folder(path: String, name: String)

    static func resolve(row: Int?, entries: [SFTPBrowserModel.Entry], currentPath: String) -> Self {
        if let row, entries.indices.contains(row), entries[row].kind == .directory {
            let entry = entries[row]
            return .folder(path: SFTPBrowserModel.joinPath(currentPath, entry.name), name: entry.displayName)
        }
        return .current(path: currentPath)
    }

    var path: String {
        switch self {
        case .current(let path), .folder(let path, _): path
        }
    }

    /// What the listing says while files are held over it.
    func prompt(count: Int) -> String {
        switch self {
        // The folder by name, as the path bar ends: a whole path ran out of
        // room before the part that says where.
        case .current(let path):
            L10n.format("sftp.drop.current", count, path == "/" ? "/" : (path as NSString).lastPathComponent)
        case .folder(_, let name): L10n.format("sftp.drop.folder", name)
        }
    }
}

@MainActor
final class SFTPDropTargetView: NSView {
    weak var model: SFTPBrowserModel?
    private var destination: SFTPDropDestination?
    private var highlightedRow: Int?
    private var itemCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks are the listing's; drags reach this view by its registered
    /// types, not by hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Dragging

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clear()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clear()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clear() }
        guard let model, let destination else { return false }
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return model.upload(urls, into: destination.path)
    }

    /// Only files from outside Corta, onto a connected listing. A row
    /// dragged out of this table passes over it on its way to Finder; that
    /// is a download, not an upload.
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let model, model.connectionState == .connected, sender.draggingSource == nil else {
            clear()
            return []
        }
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else {
            clear()
            return []
        }
        let row = tableRow(at: sender.draggingLocation)
        let resolved = SFTPDropDestination.resolve(
            row: row, entries: model.entries, currentPath: model.currentPath)
        let rowShown: Int? = if case .folder = resolved { row } else { nil }
        if resolved != destination || rowShown != highlightedRow || urls.count != itemCount {
            destination = resolved
            highlightedRow = rowShown
            itemCount = urls.count
            needsDisplay = true
        }
        return .copy
    }

    private func clear() {
        guard destination != nil else { return }
        destination = nil
        highlightedRow = nil
        itemCount = 0
        needsDisplay = true
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: - The table under the overlay

    /// The listing's table: the one in this window whose visible part holds
    /// the point (window coordinates).
    private var table: NSTableView? {
        guard let content = window?.contentView else { return nil }
        return Self.tables(in: content).first { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }

    private func tableRow(at windowPoint: NSPoint) -> Int? {
        guard let table else { return nil }
        let point = table.convert(windowPoint, from: nil)
        guard table.visibleRect.contains(point) else { return nil }
        let row = table.row(at: point)
        return row >= 0 ? row : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let destination else { return }
        let accent = NSColor.controlAccentColor
        let target: NSRect
        if let highlightedRow, let table {
            target = convert(table.rect(ofRow: highlightedRow), from: table).insetBy(dx: 4, dy: 1)
        } else {
            target = bounds.insetBy(dx: 4, dy: 4)
        }
        let shape = NSBezierPath(roundedRect: target, xRadius: 8, yRadius: 8)
        accent.withAlphaComponent(highlightedRow == nil ? 0.07 : 0.18).setFill()
        shape.fill()
        accent.setStroke()
        shape.lineWidth = 2
        shape.stroke()
        drawPill(destination.prompt(count: itemCount), in: target, onRow: highlightedRow != nil)
    }

    /// The destination in words: at the foot of the listing, or at the end
    /// of the row it is over.
    private func drawPill(_ text: String, in target: NSRect, onRow: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let width = min(size.width + 28, target.width - 16)
        let height: CGFloat = onRow ? min(22, target.height - 4) : 28
        let origin = onRow
            ? NSPoint(x: target.maxX - width - 8, y: target.midY - height / 2)
            : NSPoint(x: target.midX - width / 2, y: (isFlipped ? target.maxY - height - 12 : target.minY + 12))
        let pill = NSRect(origin: origin, size: NSSize(width: width, height: height))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
        string.draw(
            with: NSRect(x: pill.minX + 14, y: pill.midY - size.height / 2, width: width - 28, height: size.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
