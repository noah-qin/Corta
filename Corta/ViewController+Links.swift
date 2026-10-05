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

import Cocoa
import CortaTerminal

/// Opening URLs: hit-testing, hover feedback and the `NSWorkspace`
/// hand-off. Detection and the scheme allowlist (`http`/`https`/`mailto`)
/// live in the core (`LinkDetection.swift`).
///
/// ⌘-click is the default: the modifier is the confirmation
/// (`SECURITY.md` §2.4). `link-activation = click` replaces it with two
/// guards: hovering underlines and shows the real target first, and a
/// click opens only on mouse-up without movement, so a drag still
/// selects.
extension ViewController {
    var opensLinksOnPlainClick: Bool {
        ConfigurationStore.shared.configuration.linkActivation == .click
    }

    /// ⌘-click opens and consumes; anything else falls through to mouse
    /// reporting or selection. Plain clicks: `openLinkOnPlainClick`.
    func handleLinkClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        // A `path:line` resolving to a local file. URLs win; the detectors
        // don't overlap in practice, and the order makes that explicit.
        if let reference = fileReferenceUnder(event, in: terminalView) {
            return open(reference)
        }
        // Remote: open the host file's managed local copy.
        if let remoteReference = remote.resolve(detectedReferenceUnder(event, in: terminalView)) {
            return remote.open(remoteReference)
        }
        return false
    }

    /// `link-activation = click` on mouse-up, for a click that never moved.
    @discardableResult
    func openLinkOnPlainClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard opensLinksOnPlainClick, !event.modifierFlags.contains(.shift)
        else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        if let reference = fileReferenceUnder(event, in: terminalView) {
            return open(reference)
        }
        if let remoteReference = remote.resolve(detectedReferenceUnder(event, in: terminalView)) {
            return remote.open(remoteReference)
        }
        return false
    }

    /// Re-checks the scheme at the boundary where output launches another
    /// app (`SECURITY.md` §2.4).
    private func open(_ link: LinkDetection.Link) -> Bool {
        guard let url = URL(string: link.url), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Hand cursor, underline and a tooltip with the real target
    /// (`SECURITY.md` §2.4), on mouse-moved and ⌘ changes. The cursor changes
    /// on transitions only, or it flickers against `NSSplitView`'s resize
    /// cursor.
    func handleLinkHover(_ event: NSEvent, in terminalView: TerminalView) {
        // The underline must mean "this will open".
        let armed = opensLinksOnPlainClick || event.modifierFlags.contains(.command)
        if session != nil, let link = linkUnder(event, in: terminalView) {
            if armed, !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            } else if !armed, hoveringLink {
                NSCursor.arrow.set()
                hoveringLink = false
            }
            let tip = opensLinksOnPlainClick
                ? link.url : L10n.format("link.commandClick", link.url)
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(armed ? link.range : nil)
        } else if armed, session != nil,
            let reference = fileReferenceUnder(event, in: terminalView)
        {
            // The tooltip names the path and the required editor setting.
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            let target = "\(reference.url.path):\(reference.line)"
            let tip =
                ConfigurationStore.shared.configuration.openFileCommand.isEmpty
                ? L10n.format("link.fileNoLine", target) : target
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(reference.range)
        } else if armed, session != nil,
            let remoteReference = remote.resolve(detectedReferenceUnder(event, in: terminalView))
        {
            // Remote: host and path, and that a managed copy opens.
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            let tip = L10n.format(
                "link.remoteFile",
                "\(remoteReference.host):\(remoteReference.remotePath):\(remoteReference.line)")
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(remoteReference.range)
        } else {
            resetLinkHover(terminalView)
        }
    }

    /// Resets hover state, only if the hand is up.
    func resetLinkHover(_ terminalView: TerminalView) {
        if hoveringLink {
            NSCursor.arrow.set()
            hoveringLink = false
        }
        if terminalView.toolTip != nil { terminalView.toolTip = nil }
        if hoveredLink != nil {
            hoveredLink = nil
            invalidateDisplay()
        }
    }

    private func setHoveredLink(_ range: SelectionRange?) {
        guard session != nil else { return }
        let highlight = range.map { TerminalSelection($0, grid: session.snapshot()) }
        guard !Self.sameRange(hoveredLink, highlight) else { return }
        hoveredLink = highlight
        invalidateDisplay()
    }

    private static func sameRange(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.start == b.start && a.end == b.end
            && a.baseScrollbackTotal == b.baseScrollbackTotal
    }

    /// Through the same mapping selection uses.
    private func linkUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> LinkDetection.Link?
    {
        guard session != nil, terminalRenderer != nil else { return nil }
        let grid = session.snapshot()
        let point = documentPosition(for: event, in: terminalView, grid: grid)
        return LinkDetection.link(at: point, in: grid)
    }
}
