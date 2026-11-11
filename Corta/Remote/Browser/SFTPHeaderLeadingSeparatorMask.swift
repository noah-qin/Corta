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

/// Removes the leading column separator the inset table style draws in the
/// header before the first column (#530).
///
/// The header is a stock, transparent `NSTableHeaderView` over the table's
/// content background. Clipping it to the first column's own leading edge
/// drops the separator that has no column to its left and leaves the
/// separators between columns untouched; nothing is painted, so both
/// appearances and any window size follow the table.
struct SFTPHeaderLeadingSeparatorMask: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Mask() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Mask)?.install()
    }

    private final class Mask: NSView {
        private weak var header: NSTableHeaderView?
        private var retries = 0
        // Touched from a `deinit`, which cannot use main-actor state: the
        // header's layer, so its mask is cleared even if the view is never
        // detached from the window, and the frame observer.
        nonisolated(unsafe) private weak var headerLayer: CALayer?
        nonisolated(unsafe) private weak var installedMask: CALayer?
        nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A later window attachment gets its own retry budget: the header
            // can be missing during the first one and appear by the next.
            retries = 0
            if window == nil {
                removeMask()
            } else {
                install()
            }
        }

        /// The table's header is created in a layout pass after this view joins
        /// the window, so the first attempts retry on the next main-queue turns.
        func install() {
            guard window != nil else {
                retries = 0
                return
            }
            guard let content = window?.contentView, let header = Self.header(in: content) else {
                retries += 1
                if retries <= 10 {
                    DispatchQueue.main.async { [weak self] in self?.install() }
                }
                return
            }
            retries = 0
            if header === self.header {
                // Already bound: put the clip back if something took it off.
                if header.layer?.mask == nil || header.layer?.mask !== installedMask { applyMask() }
                return
            }
            removeMask()
            self.header = header
            header.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: header, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMask() }
            }
            applyMask()
        }

        private func applyMask() {
            guard let header, let table = header.tableView, table.numberOfColumns > 0 else { return }
            let leading = table.rect(ofColumn: 0).minX
            header.wantsLayer = true
            headerLayer = header.layer
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = CGRect(
                x: leading, y: 0,
                width: max(0, header.bounds.width - leading), height: header.bounds.height)
            header.layer?.mask = mask
            installedMask = mask
        }

        private func removeMask() {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            frameObserver = nil
            // Only a clip this view installed: a successor installer may
            // already have clipped the same header.
            if let installedMask, header?.layer?.mask === installedMask { header?.layer?.mask = nil }
            installedMask = nil
            headerLayer = nil
            header = nil
            retries = 0
        }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            // Only what this view installed: a successor may already have
            // masked the same header.
            if let installedMask, headerLayer?.mask === installedMask { headerLayer?.mask = nil }
        }

        private static func header(in view: NSView) -> NSTableHeaderView? {
            if let header = view as? NSTableHeaderView { return header }
            for subview in view.subviews {
                if let header = header(in: subview) { return header }
            }
            return nil
        }
    }
}
