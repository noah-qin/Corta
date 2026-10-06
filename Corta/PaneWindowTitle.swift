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
import QuartzCore
import Synchronization

/// One pane's window title and proxy icon: what they say, the process facts
/// behind them, and when those are read.
///
/// `⟂ host — <title or directory> — <process> — <columns>×<rows>`, as
/// Terminal.app shows; unknown parts are left out. Rebuilt on the output
/// batch (`PaneFrameLoop.onOutputBatch`) and at command boundaries, focus
/// and resizes; the pane decides when, this decides what.
final class PaneWindowTitle {
    /// The session whose facts the title reports; replaced with it.
    var session: TerminalSession?
    /// One fresh read of the pane's remote state (`PaneRemoteState`).
    var resolveRemoteState: () -> PaneRemoteState = { .local }
    /// The window the title is applied to.
    var window: () -> NSWindow? = { nil }
    /// The grid size last sent to the child, shown while it is changing.
    var gridSize: () -> TerminalSize? = { nil }
    /// Whether a deferred rebuild may still apply: the pane is open and
    /// focused. An unfocused pane's title applies on focus.
    var canApplyDeferred: () -> Bool = { false }
    /// Whether a path is a directory — a `stat`, which can block on a mount
    /// that never answers, so it runs off the main actor.
    private let isDirectory: @Sendable (String) -> Bool

    init(isDirectory: @escaping @Sendable (String) -> Bool = PaneWindowTitle.isDirectoryOnDisk) {
        self.isDirectory = isDirectory
    }

    nonisolated static func isDirectoryOnDisk(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var cachedProcessName: String?
    private var cachedDirectory: String?
    /// `cachedDirectory` if it was a directory when it last changed: the
    /// title bar's proxy icon.
    private(set) var representedDirectory: URL?
    private var directoryProbeGeneration = 0
    // At most two blocked filesystem probes process-wide. Admission does not
    // queue work: a hung mount must not grow a backlog of threads or closures.
    nonisolated private static let directoryProbes = Mutex(0)
    private var cachedRemoteState: PaneRemoteState = .local
    private var lastProcessFactsRefresh: CFTimeInterval = 0
    /// A title rebuild waiting out `processFactsInterval`; at most one, and
    /// cancelled by `stop`.
    private var trailingTitleRefresh: DispatchWorkItem?
    private var isShowingTransientSize = false
    private var transientSizeReset: DispatchWorkItem?
    private var isStopped = false

    /// A new session: its facts are unknown, and it starts local.
    func reset(session: TerminalSession) {
        self.session = session
        invalidateProcessFacts()
        cachedRemoteState = .local
    }

    /// The pane closed: nothing deferred may apply after this.
    func stop() {
        isStopped = true
        directoryProbeGeneration += 1
        trailingTitleRefresh?.cancel()
        trailingTitleRefresh = nil
        transientSizeReset?.cancel()
        transientSizeReset = nil
    }

    /// Every part but the size is child input: capped and stripped of
    /// controls (`SECURITY.md` §2). The host badge leads — it answers which
    /// computer the rest is on — and an OSC 0/2 title beats the directory.
    var composed: String {
        guard let session else { return "Corta" }
        refreshProcessFactsIfStale(session)
        var parts: [String] = []
        // The badge's host and directory are the remote shell's own OSC 7
        // text, percent-decoded — as hostile as any other child-supplied
        // component, and sanitised the same way.
        if let badge = Self.sanitizedTitleComponent(cachedRemoteState.titleComponent) {
            parts.append(badge)
        }
        if let title = Self.sanitizedTitleComponent(session.windowTitle) {
            parts.append(title)
        } else if let directory = Self.sanitizedTitleComponent(cachedDirectory.map(Self.abbreviated)) {
            // OSC 7 text too: a directory named with a newline or a bidi
            // override would otherwise reach the title as it is.
            parts.append(directory)
        }
        if let process = Self.sanitizedTitleComponent(cachedProcessName) {
            parts.append(process)
        }
        // The grid size, only while it is changing.
        //
        // Appended permanently, the title would read "~/Corta — zsh —
        // 120×27" for the whole life of the window: a third of the space,
        // and with tabs a third of every tab label, spent on a number that
        // is interesting for the two seconds of a drag and never again.
        // Terminal.app shows it during a resize for exactly that reason.
        // With tabs the cost is worse than cosmetic — the tab label
        // truncates from the right, so the directory or task name the user
        // is actually distinguishing tabs by would be the first thing to
        // disappear.
        if let size = gridSize(), isShowingTransientSize {
            parts.append("\(size.columns)×\(size.rows)")
        }
        return parts.isEmpty ? "Corta" : parts.joined(separator: " — ")
    }

    /// Applies the title to the window, plus the proxy icon for the working
    /// directory — the folder in the title bar, which makes the path
    /// draggable and ⌘-clickable the way every document window's is.
    ///
    /// The represented URL is only set for a directory that exists: the path
    /// arrives over OSC 7 from the child, and a proxy icon is something the
    /// user can drag into another application. A remote pane gets no icon at
    /// all, by construction rather than by check: `cachedDirectory` reads
    /// `session.currentDirectory`, which a remote `OSC 7` report never
    /// reaches (it lands in `remoteContext`), so there is no remote
    /// path here to offer a drag of.
    func apply() {
        guard let window = window() else { return }
        let title = (window.windowController as? TerminalWindowController)?.customTabTitle ?? composed
        if window.title != title { window.title = title }
        (window.windowController as? TerminalWindowController)?.refreshTabTitle()

        if window.representedURL != representedDirectory {
            window.representedURL = representedDirectory
        }
    }

    static let directoryProbeRetryDelay: TimeInterval = 2

    /// OSC 7 paths can point at an unresponsive network mount. Never stat on
    /// the main actor, and never publish a result for a superseded path.
    func probeRepresentedDirectory(_ path: String?) {
        directoryProbeGeneration += 1
        let generation = directoryProbeGeneration
        representedDirectory = nil
        guard let path else { return }
        let admitted = Self.directoryProbes.withLock { active in
            guard active < 2 else { return false }
            active += 1
            return true
        }
        // Two probes are already stuck on a slow mount. Try again shortly,
        // rather than leave this pane without its proxy icon until the next
        // `cd`; a newer path in the meantime supersedes the retry.
        guard admitted else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.directoryProbeRetryDelay) {
                [weak self] in
                guard let self, !self.isStopped, generation == self.directoryProbeGeneration
                else { return }
                self.probeRepresentedDirectory(path)
            }
            return
        }
        let isDirectory = isDirectory
        Task.detached(priority: .utility) { [weak self] in
            let exists = isDirectory(path)
            Self.directoryProbes.withLock { $0 -= 1 }
            await MainActor.run { [weak self] in
                guard let self, !self.isStopped,
                    generation == self.directoryProbeGeneration else { return }
                self.representedDirectory = exists ? URL(fileURLWithPath: path) : nil
                self.apply()
            }
        }
    }

    /// Shows the grid size in the title for a moment after a resize, then
    /// takes it away again.
    func noteTransientSizeChange() {
        isShowingTransientSize = true
        transientSizeReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            isShowingTransientSize = false
            transientSizeReset = nil
            apply()
        }
        transientSizeReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transientSizeDuration, execute: work)
    }

    /// A size change that was not a drag (zoom, a font change): no label.
    func endTransientSize() {
        transientSizeReset?.cancel()
        transientSizeReset = nil
        isShowingTransientSize = false
    }

    private static let transientSizeDuration: TimeInterval = 1.5

    /// The process name, directory and remote state behind the title, and
    /// when they were last read.
    ///
    /// All three are syscalls — `tcgetpgrp`, `proc_name`, `proc_pidinfo` —
    /// and the title is rebuilt on every output batch, which during a `yes`
    /// or a build is thousands of batches a second. Refreshed on an interval
    /// instead: a directory that changed a quarter of a second ago is not
    /// worth three syscalls per frame, and the OSC 0/2 title (the part a
    /// program updates deliberately) is read fresh every time regardless.
    /// The remote state rides the same cadence: `ssh` starting or
    /// exiting announces itself with output — the far end's banner, the
    /// local shell's returning prompt — so the badge follows within one
    /// interval, with no timer of its own.
    private func refreshProcessFactsIfStale(_ session: TerminalSession) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastProcessFactsRefresh
        guard elapsed >= Self.processFactsInterval else {
            scheduleTrailingTitleRefresh(after: Self.processFactsInterval - elapsed)
            return
        }
        lastProcessFactsRefresh = now
        cachedProcessName = session.activeProcessName
        let directory = session.currentDirectory
        if directory != cachedDirectory {
            cachedDirectory = directory
            probeRepresentedDirectory(directory)
        }
        cachedRemoteState = resolveRemoteState()
    }

    /// One more title rebuild once the interval has passed. A skipped refresh
    /// is only stale if nothing follows it, and a program that exits and hands
    /// back the prompt within the interval is followed by nothing: without
    /// this, `kitten icat` left "— kitten" in the title until the next output.
    private func scheduleTrailingTitleRefresh(after delay: CFTimeInterval) {
        guard trailingTitleRefresh == nil, !isStopped else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            trailingTitleRefresh = nil
            guard !isStopped, canApplyDeferred() else { return }
            apply()
        }
        trailingTitleRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// On focus and command boundaries, where waiting out the interval would
    /// show something stale.
    func invalidateProcessFacts() {
        lastProcessFactsRefresh = 0
    }

    private static let processFactsInterval: CFTimeInterval = 0.4

    /// No controls (a newline truncates a title) and a hard length cap.
    private static func sanitizedTitleComponent(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned =
            text
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > titleComponentLimit else { return cleaned }
        return cleaned.prefix(titleComponentLimit) + "…"
    }

    private static let titleComponentLimit = 80

    /// `~/Developer`, or just the last name deeper down; the proxy icon has the
    /// full path.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
