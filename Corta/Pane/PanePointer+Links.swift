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
import CortaTerminal

extension PanePointer {
    // MARK: - Links and file references

    var opensLinksOnPlainClick: Bool {
        ConfigurationStore.shared.configuration.linkActivation == .click
    }

    /// ⌘-click opens and consumes; anything else falls through to mouse
    /// reporting or selection. Plain clicks: `openLinkOnPlainClick`.
    func handleLinkClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        // A `path:line`, local or remote. URLs win; the detectors don't
        // overlap in practice, and the order makes that explicit.
        return openReference(under: event, in: terminalView)
    }

    /// `link-activation = click` on mouse-up, for a click that never moved.
    @discardableResult
    func openLinkOnPlainClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard opensLinksOnPlainClick, !event.modifierFlags.contains(.shift)
        else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        return openReference(under: event, in: terminalView)
    }

    /// Re-checks the scheme at the boundary where output launches another
    /// app (`SECURITY.md` §2.4).
    func open(_ link: LinkDetection.Link) -> Bool {
        guard let url = Self.target(of: link.url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// The URL a link opens, and so the one its tooltip names: allowlisted
    /// scheme, host in IDNA form, anything invisible percent-encoded, and no
    /// userinfo. Shown raw, `https://аpple.com` read as Apple while opening
    /// `xn--pple-43d.com`, and `https://github.com@evil.example` named the
    /// wrong host first; the destination is what `SECURITY.md` §2.4 says to show.
    nonisolated static func target(of raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Hand cursor, underline and a tooltip with the real target
    /// (`SECURITY.md` §2.4), on mouse-moved and ⌘ changes. The cursor changes
    /// on transitions only, or it flickers against `NSSplitView`'s resize
    /// cursor.
    func handleLinkHover(_ event: NSEvent, in terminalView: TerminalView) {
        if lastHover?.event !== event { lastHover = nil }
        // The underline must mean "this will open".
        let armed = opensLinksOnPlainClick || event.modifierFlags.contains(.command)
        if session != nil, let link = linkUnder(event, in: terminalView) {
            if armed, !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            } else if !armed, hoveringLink {
                programCursor.set()
                hoveringLink = false
            }
            let target = Self.target(of: link.url)?.absoluteString ?? ""
            let tip = opensLinksOnPlainClick
                ? target : L10n.format("link.commandClick", target)
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(armed ? link.range : nil)
        } else if armed, session != nil,
            let reference = hoverReference(event, in: terminalView)
        {
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            let tip: String
            switch reference {
            case .local(let local):
                // The path and the required editor setting.
                let target = "\(local.url.path):\(local.line)"
                tip = ConfigurationStore.shared.configuration.openFileCommand.isEmpty
                    ? L10n.format("link.fileNoLine", target) : target
            case .remote(let remote):
                // Host and path, and that a managed copy opens.
                tip = L10n.format(
                    "link.remoteFile", "\(remote.host):\(remote.remotePath):\(remote.line)")
            }
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(reference.range)
        } else {
            resetLinkHover(terminalView)
        }
    }

    /// The reference under a hover, if known now. A local path still being
    /// checked shows nothing yet; its answer replays the hover, if the
    /// pointer has not moved on.
    private func hoverReference(_ event: NSEvent, in terminalView: TerminalView) -> OpenableReference? {
        let detected = detectedReferenceUnder(event, in: terminalView)
        switch lookUpReference(detected) {
        case .resolved(let reference):
            lastHoverReference = reference
            return reference
        case .pending(let path):
            // The same reference still under the pointer as its answer ages
            // out: keep showing it while it is checked again, or the
            // underline flickered every `lifetime`.
            if let last = lastHoverReference, let detected, last.range == detected.range {
                fileProbe.probe(path) { _ in }
                return last
            }
            lastHover = (event, terminalView)
            fileProbe.probe(path) { [weak self] _ in
                guard let self, let hover = self.lastHover, hover.event === event else { return }
                self.handleLinkHover(hover.event, in: hover.view)
            }
            return nil
        }
    }

    /// Resets hover state, only if the hand is up.
    func resetLinkHover(_ terminalView: TerminalView) {
        if hoveringLink {
            programCursor.set()
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
    func linkUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> LinkDetection.Link?
    {
        guard session != nil, terminalRenderer != nil else { return nil }
        let grid = session.snapshot()
        let point = documentPosition(for: event, in: terminalView, grid: grid)
        // A link that cannot open — an OSC 8 `ftp:` or `file:` target — is no
        // link: no hand, no underline, and no tooltip showing its raw text.
        guard let link = LinkDetection.link(at: point, in: grid), Self.target(of: link.url) != nil
        else { return nil }
        return link
    }

    /// A reference known to name an existing local file.
    struct ResolvedFileReference: Equatable {
        var url: URL
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves a reference against a directory, or refuses. Pure, with the
    /// filesystem check injected.
    ///
    /// - Parameter reference: a detected path, with its line and column.
    /// - Parameter directory: the pane's local working directory. Nil (remote
    ///   or unreported) refuses even absolute paths, which name remote files
    ///   there too.
    /// - Parameter isRegularFile: the filesystem check; tests pass their own.
    static func resolve(
        _ reference: FileReferenceDetection.Reference, directory: String?,
        isRegularFile: (String) -> Bool = PathProbe.isRegularFile
    ) -> ResolvedFileReference? {
        guard let path = candidatePath(reference, directory: directory), isRegularFile(path)
        else { return nil }
        return resolved(reference, at: path)
    }

    /// The absolute path a reference names from `directory`, before any
    /// filesystem check; nil without a local directory.
    nonisolated static func candidatePath(
        _ reference: FileReferenceDetection.Reference, directory: String?
    ) -> String? {
        guard let directory else { return nil }
        let expanded = (reference.path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/")
            ? expanded
            : (directory as NSString).appendingPathComponent(expanded)
        // Resolves `..`, so the path checked is the path opened. Not a sandbox:
        // the shell can read anything the user can.
        return (absolute as NSString).standardizingPath
    }

    private nonisolated static func resolved(
        _ reference: FileReferenceDetection.Reference, at path: String
    ) -> ResolvedFileReference {
        ResolvedFileReference(
            url: URL(fileURLWithPath: path), line: reference.line,
            column: reference.column, range: reference.range)
    }

    /// What a detected `path:line` opens: the local file it names, else the
    /// remote host's. One detection serves both — the pattern scan runs on the
    /// main thread, and it ran twice per ⌘ press over text that matched nothing.
    enum OpenableReference {
        case local(ResolvedFileReference)
        case remote(PaneRemote.ResolvedReference)

        var range: SelectionRange {
            switch self {
            case .local(let reference): reference.range
            case .remote(let reference): reference.range
            }
        }
    }

    /// What a detected reference opens, as far as is known without blocking:
    /// whether a local path is a file comes from `FileReferenceProbe`, off the
    /// main thread — a `stat` here, per mouse move, froze the app on a mount
    /// that stopped answering. `pending` is a path still being checked.
    enum ReferenceLookup {
        case resolved(OpenableReference?)
        case pending(path: String)
    }

    func lookUpReference(_ detected: FileReferenceDetection.Reference?) -> ReferenceLookup {
        guard let detected else { return .resolved(nil) }
        if let path = Self.candidatePath(detected, directory: session.workingDirectory) {
            switch fileProbe.cached(path) {
            case true?: return .resolved(.local(Self.resolved(detected, at: path)))
            case nil: return .pending(path: path)
            case false?: break
            }
        }
        return .resolved(host?.remote.resolve(detected).map(OpenableReference.remote))
    }

    /// Opens what is under `event` once the local check has answered; the
    /// click is taken either way, since it named a reference.
    private func openReference(under event: NSEvent, in terminalView: TerminalView) -> Bool {
        let detected = detectedReferenceUnder(event, in: terminalView)
        if case .resolved(nil) = lookUpReference(detected) { return false }
        openDetected(detected)
        return true
    }

    /// Opens what `detected` names, once a pending local check has answered;
    /// `otherwise` runs when it names nothing that opens.
    func openDetected(
        _ detected: FileReferenceDetection.Reference?, otherwise: @escaping () -> Void = {}
    ) {
        switch lookUpReference(detected) {
        case .resolved(let reference?):
            open(reference)
        case .resolved(nil):
            otherwise()
        case .pending(let path):
            fileProbe.probe(path) { [weak self] _ in
                guard let self else { return }
                if case .resolved(let reference?) = self.lookUpReference(detected) {
                    self.open(reference)
                } else {
                    otherwise()
                }
            }
        }
    }

    @discardableResult
    func open(_ reference: OpenableReference) -> Bool {
        switch reference {
        case .local(let local): open(local)
        case .remote(let remote): host?.remote.open(remote) ?? false
        }
    }

    /// Detection before resolution, shared with the remote path
    /// (`PaneRemote.resolve`).
    func detectedReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> FileReferenceDetection.Reference?
    {
        guard isOperable, let terminalRenderer else { return nil }
        let grid = session.snapshot()
        let point = Self.documentPosition(
            for: terminalView.convert(event.locationInWindow, from: nil), grid: grid, scrollOffset: scrollOffset,
            in: GridGeometry(
                viewHeight: terminalView.bounds.height, metrics: terminalRenderer.pointMetrics, topInset: topInset))
        return FileReferenceDetection.reference(at: point, in: grid)
    }

    @discardableResult
    func open(_ reference: ResolvedFileReference) -> Bool {
        let opened = Self.openFileAt(
            url: reference.url, line: reference.line, column: reference.column)
        if !opened {
            terminalView?.showToast(L10n.text("toast.badOpenFileCommand"), kind: .warning)
        }
        return opened
    }

    /// Opens a local file, at the line if the configured command takes one;
    /// shared by local references and `RemoteEditCoordinator`'s managed
    /// copies. Output-derived files require `open-file-command`: a default
    /// application can execute a .command or .terminal file. Runs via `Process` with
    /// separate arguments, **never a shell**, which would revive the path's
    /// metacharacters (`SECURITY.md` §2.3).
    @discardableResult
    static func openFileAt(url: URL, line: Int, column: Int?, command: String? = nil) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false, command: command)
    }

    /// Remote bytes must go to an explicitly configured editor, never to a
    /// LaunchServices handler that could execute a .command or .terminal file.
    static func openRemoteFileAt(url: URL, line: Int, column: Int?) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false)
    }

    static func openFileAt(
        url: URL, line: Int, column: Int?, allowsDefaultApplication: Bool,
        command: String? = nil
    ) -> Bool {
        let template = command ?? ConfigurationStore.shared.configuration.openFileCommand
        guard !template.isEmpty else {
            guard allowsDefaultApplication else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
        let arguments = openFileArguments(
            template: template, path: url.path, line: line, column: column)
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            // Absolute only: a bare name would resolve through the shell's PATH.
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// The last reference in `record`'s output, walking backwards: closest to
    /// where a build tool says what went wrong. Bounded in rows scanned, and a
    /// line longer than a hover may scan is skipped unjoined, so a huge log
    /// without one isn't a full scan on the main thread — menu validation
    /// runs this.
    func detectedReferenceInCommand(_ record: CommandRecord?)
        -> FileReferenceDetection.Reference?
    {
        guard let record, isOperable else { return nil }
        let start = record.outputStartRow ?? record.promptRow + 1
        let grid = session.snapshot()
        let base = grid.scrollback.totalPushed
        let end = record.endRow ?? grid.absoluteRow(ofScreenRow: grid.cursor.row)
        let startDoc = start - base
        var row = end - base - 1
        var rowsScanned = 0
        while row >= startDoc, rowsScanned < Self.maxCommandOutputRowsScanned {
            let line = FileReferenceDetection.references(inLineContaining: row, in: grid)
            rowsScanned += row - line.firstRow + 1
            if let reference = line.references.last { return reference }
            row = line.firstRow - 1
        }
        return nil
    }

    private static let maxCommandOutputRowsScanned = 2000

    /// Substitutes `{file}`, `{line}` and `{column}` per argument, splitting the
    /// user's template before substitution so a path with spaces stays one
    /// argument. Pure and `nonisolated`.
    nonisolated static func openFileArguments(
        template: String, path: String, line: Int, column: Int?
    ) -> [String] {
        let values = ["{file}": path, "{line}": String(line), "{column}": String(column ?? 1)]
        // One pass over the template's own text: replaced one after another, a
        // file named `a{line}` became `a12` — a different file from the one
        // checked to exist, and remote names are the server's to choose.
        return template.split(whereSeparator: \.isWhitespace).map { part in
            var result = ""
            var rest = part[...]
            while !rest.isEmpty {
                if let (token, value) = values.first(where: { rest.hasPrefix($0.key) }) {
                    result += value
                    rest = rest.dropFirst(token.count)
                } else {
                    result.append(rest.removeFirst())
                }
            }
            return result
        }
    }
}
