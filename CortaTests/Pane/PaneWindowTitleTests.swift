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
import Foundation
import Synchronization
import Testing

@testable import Corta
@testable import CortaTerminal

/// The window title's own state, without a pane: when the size shows, and
/// the proxy icon's directory probe, which must never block the main actor
/// on a mount that does not answer.
///
/// Serialized: the directory-probe tests share the process-wide admission of
/// two, and one of them deliberately fills it.
@MainActor
@Suite(.serialized)
struct PaneWindowTitleTests {
    /// Blocked on a dead mount, a pool thread is one of the few every task in
    /// the app shares.
    @Test("the directory check runs on a probe thread of its own")
    func directoryCheckIsOffThePool() async {
        let name = Mutex<String?>(nil)
        let title = PaneWindowTitle(isDirectory: { _ in
            name.withLock { $0 = Thread.current.name }
            return true
        })
        title.probeRepresentedDirectory("/somewhere")
        let deadline = SuspendingClock.now + .seconds(5) * testTimeoutScale
        while name.withLock({ $0 }) == nil, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(name.withLock { $0 } == "dev.noahqin.Corta.path-probe")
    }

    @Test("without a session the title is the app's name")
    func noSessionIsCorta() {
        #expect(PaneWindowTitle().composed == "Corta")
    }

    @Test("the grid size shows only while a resize is being noted")
    func transientSizeComesAndGoes() throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        let title = PaneWindowTitle()
        defer { title.stop() }
        title.reset(session: session)
        title.gridSize = { TerminalSize(rows: 24, columns: 80) }
        #expect(!title.composed.contains("80×24"))
        title.noteTransientSizeChange()
        #expect(title.composed.contains("80×24"))
        title.endTransientSize()
        #expect(!title.composed.contains("80×24"))
    }

    /// `cat` echoes the sequence back as output: the program's title.
    @Test("the finished-task notice is titled by the directory, not by an OSC 2 title")
    func notificationTitleIgnoresProgramTitle() async throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/usr")
        defer { session.stop() }
        session.start()
        let title = PaneWindowTitle()
        defer { title.stop() }
        title.reset(session: session)
        session.write(Array("\u{1B}]2;Security update: run sudo fix\u{07}\n".utf8))
        let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        while session.windowTitle == nil, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(title.composed.contains("Security update"))
        #expect(title.notificationTitle == "usr")
    }

    /// Two probes stuck on a slow mount fill the admission; a third pane's
    /// probe is retried once there is room rather than dropped, so the pane
    /// gets its proxy icon without waiting for its next `cd`.
    @Test("a probe refused while two are stuck runs when one ends, not dropped")
    func refusedProbeIsRetried() async {
        let release = DispatchSemaphore(value: 0)
        let entered = Mutex(0)
        let stuck = (0..<2).map { _ in
            PaneWindowTitle(isDirectory: { _ in
                entered.withLock { $0 += 1 }
                release.wait()
                return true
            })
        }
        for title in stuck { title.probeRepresentedDirectory("/slow-mount") }
        var deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        while entered.withLock({ $0 }) < 2, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 } == 2)

        let asked = Mutex(false)
        let third = PaneWindowTitle(isDirectory: { _ in
            asked.withLock { $0 = true }
            return true
        })
        third.probeRepresentedDirectory("/fine")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!asked.withLock { $0 }, "no room yet: two probes hold the admission")

        release.signal()
        release.signal()
        // Woken by a probe's end, not a timer: well inside a second.
        deadline = SuspendingClock.now + .seconds(1) * testTimeoutScale
        while !asked.withLock({ $0 }), SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(asked.withLock { $0 }, "the refused probe ran once there was room")
        for title in stuck + [third] { title.stop() }
    }

    @Test("a blocked directory probe does not block the main actor")
    func slowDirectoryProbeIsBackgroundWork() async {
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let title = PaneWindowTitle(isDirectory: { _ in
            entered.withLock { $0 = true }
            release.wait()
            return true
        })
        defer { release.signal() }
        title.probeRepresentedDirectory("/slow-mount")
        let deadline = SuspendingClock.now + .seconds(3 * testTimeoutScale)
        while !entered.withLock({ $0 }), SuspendingClock.now < deadline {
            await Task.yield()
        }
        #expect(entered.withLock { $0 })
        title.probeRepresentedDirectory(nil)
        title.stop()
    }
}

extension PaneWindowTitleTests {
    /// Reading the title for a strip or a header must not schedule anything:
    /// two tabs' strip passes kept re-arming each other's refresh for as long
    /// as the tabs were open, with no output at all.
    @Test("showing a title schedules no refresh; applying it does")
    func displayedTitleSchedulesNothing() throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        let title = PaneWindowTitle()
        defer { title.stop() }
        title.reset(session: session)
        _ = title.tabLabel
        _ = title.displayedTitle
        #expect(!title.hasTrailingRefresh)
        _ = title.composed
        #expect(title.hasTrailingRefresh)
    }

    /// A covered window shows no title: output there leaves the process
    /// facts unread until the window shows again.
    @Test("output in a covered window defers the title refresh until it shows")
    func coveredWindowDefersTheRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let title = PaneWindowTitle(isDirectory: { _ in true })
        title.window = { window }
        defer { title.stop() }
        // Never ordered in: not visible.
        #expect(!window.occlusionState.contains(.visible))
        title.noteOutput()
        #expect(title.refreshWhenVisible)
        #expect(!title.hasTrailingRefresh)
    }

    /// Counts what reaches the titlebar, which is where the cost is.
    private final class CountingWindow: NSWindow {
        var titleSets: [String] = []
        override var title: String {
            didSet { titleSets.append(title) }
        }
    }

    /// `cat` echoes each OSC 2 back as output, which retitles the pane.
    private func retitle(_ session: TerminalSession, _ text: String) async {
        session.write(Array("\u{1B}]2;\(text)\u{07}\n".utf8))
        let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        while session.windowTitle != text, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Reading the title starts the proxy icon's directory probe, whose
    /// answer applies the title at once (not from output); let it land so it
    /// is not counted as one of the output's changes.
    private func settle(_ title: PaneWindowTitle) async {
        title.apply()
        // The probe answers `true` (`isDirectory`), and applies as it does.
        let deadline = SuspendingClock.now + .seconds(5) * testTimeoutScale
        while title.representedDirectory == nil, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(title.representedDirectory != nil)
        title.apply()
    }

    /// A program retitling faster than the interval reaches the titlebar
    /// once, then once more when the interval ends, with the last title.
    @Test("titles from output inside the interval make one change, then the last one")
    func outputTitlesAreCoalesced() async throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        session.start()
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var clock: CFTimeInterval = 1_000
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let title = PaneWindowTitle(
            isDirectory: { _ in true }, now: { clock },
            scheduleAfter: { delay, work in scheduled.append((delay, work)) })
        defer { title.stop() }
        title.reset(session: session)
        title.window = { window }
        title.isWindowVisible = { _ in true }
        // Off while the loop runs: on a slow runner it outlasts the 0.4 s
        // process-facts refresh, whose own deferred apply would count here.
        var deferredAllowed = false
        title.canApplyDeferred = { deferredAllowed }
        await settle(title)
        window.titleSets.removeAll()

        for index in 0..<10 {
            await retitle(session, "t \(index)")
            title.apply(fromOutput: true)
            clock += 0.009
        }
        #expect(window.titleSets.count == 1)
        #expect(window.titleSets.first?.contains("t 0") == true)
        #expect(scheduled.count == 1)
        clock += PaneWindowTitle.windowTitleInterval
        deferredAllowed = true
        scheduled.removeFirst().work()
        #expect(window.titleSets.count == 2)
        #expect(window.title.contains("t 9"))
        #expect(scheduled.isEmpty)
    }

    /// Focus, a finished command or a rename shows the title at once, and a
    /// trailing update already scheduled has nothing left to do.
    @Test("a title applied for focus is immediate and drops the trailing one")
    func nonOutputTitleIsImmediate() async throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        session.start()
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clock: CFTimeInterval = 1_000
        var scheduled: [() -> Void] = []
        let title = PaneWindowTitle(
            isDirectory: { _ in true }, now: { clock }, scheduleAfter: { _, work in scheduled.append(work) })
        defer { title.stop() }
        title.reset(session: session)
        title.window = { window }
        title.isWindowVisible = { _ in true }
        // The process-facts refresh applies too when it may; it must not here.
        title.canApplyDeferred = { false }
        await settle(title)
        await retitle(session, "first")
        title.apply(fromOutput: true)
        await retitle(session, "second")
        title.apply(fromOutput: true)
        #expect(!window.title.contains("second"))
        await retitle(session, "third")
        title.apply()
        #expect(window.title.contains("third"))
        window.titleSets.removeAll()
        for work in scheduled { work() }
        #expect(window.titleSets.isEmpty)
    }

    /// A pane that lost focus inside the interval leaves the window's title
    /// to the pane that has it.
    @Test("the trailing title does not apply once the pane may not")
    func trailingTitleRespectsFocus() async throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        session.start()
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var scheduled: [() -> Void] = []
        let title = PaneWindowTitle(
            isDirectory: { _ in true }, now: { 1_000 }, scheduleAfter: { _, work in scheduled.append(work) })
        defer { title.stop() }
        title.reset(session: session)
        title.window = { window }
        title.isWindowVisible = { _ in true }
        var focused = true
        title.canApplyDeferred = { focused }
        await settle(title)
        await retitle(session, "mine")
        title.apply(fromOutput: true)
        await retitle(session, "later")
        title.apply(fromOutput: true)
        focused = false
        window.titleSets.removeAll()
        for work in scheduled { work() }
        #expect(window.titleSets.isEmpty)
    }
}
