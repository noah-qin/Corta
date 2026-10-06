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
import Synchronization
import Testing

@testable import Corta
import CortaTerminal

/// Copy and export build their (potentially whole-scrollback) text off
/// the interaction path, sharing one cancellable `largeTextTask` handle.
///
/// `.serialized`, with a genuine shell: copy runs `PaneCommands` over a real
/// session's grid, and teardown a real pane, like `PaneTeardownTests`.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct LargeTextTaskTests {
    private func makePane() -> ViewController {
        let pane = ViewController()
        _ = pane.view
        return pane
    }

    @MainActor
    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds * Double(testTimeoutScale))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Parks a text build until released, and says when one arrived.
    private final class BuildGate: Sendable {
        let entered = Mutex(false)
        let released = Mutex(false)

        func park() {
            entered.withLock { $0 = true }
            while !released.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
        }
    }

    /// Copy, held: `PaneCommands` over a real shell's grid, given a private
    /// pasteboard — never `.general`, the developer's own clipboard, which
    /// `NativeIntegrationTests` avoids with `.withUniqueName()` too — and a
    /// text build that parks until released. `Task.detached` gives no
    /// scheduling barrier: for a grid this small, "hasn't landed yet" right
    /// after `copy(_:)` would pass or fail with the scheduler, not with
    /// whether the build is asynchronous. The park makes it deterministic.
    @MainActor private final class HeldCopy {
        let host = CommandsTestHost()
        let session: TerminalSession
        let pasteboard = NSPasteboard.withUniqueName()
        let gate = BuildGate()
        let commands: PaneCommands

        init() throws {
            session = try TerminalSession(
                executable: "/bin/sh", arguments: ["-c", "echo COPYTASKMARKER; exec sleep 60"])
            let gate = gate
            commands = PaneCommands(host: host, pasteboard: pasteboard) { range, grid in
                gate.park()
                return Selection.text(of: range, in: grid)
            }
            host.session = session
            session.start()
        }

        func stop() {
            gate.released.withLock { $0 = true }
            commands.stop()
            session.stop()
            pasteboard.releaseGlobally()
        }
    }

    private func makeHeldCopy() async throws -> HeldCopy {
        let copy = try HeldCopy()
        let session = copy.session
        #expect(await waitUpTo(10) {
            session.snapshot().logicalLines().contains { $0.text.contains("COPYTASKMARKER") }
        })
        let grid = session.snapshot()
        // The whole document, same range ⌘A builds — simplest way to be
        // sure the marker is inside it regardless of exact row layout.
        copy.host.selection = TerminalSelection(
            start: GridPosition(row: -grid.scrollback.count, column: 0),
            end: GridPosition(row: grid.rows - 1, column: grid.columns - 1),
            baseScrollbackTotal: grid.scrollback.totalPushed)
        return copy
    }

    @Test func copyBuildsOffMainThreadAndLandsOnThePasteboard() async throws {
        let copy = try await makeHeldCopy()
        defer { copy.stop() }
        let markerBefore = "sentinel-\(UUID().uuidString)"
        copy.pasteboard.clearContents()
        copy.pasteboard.setString(markerBefore, forType: .string)

        copy.commands.copy(nil)
        #expect(await waitUpTo(5) { copy.gate.entered.withLock { $0 } })
        #expect(
            copy.pasteboard.string(forType: .string) == markerBefore,
            "the build is parked before touching the pasteboard")
        #expect(copy.commands.largeTextTask != nil)

        copy.gate.released.withLock { $0 = true }

        #expect(
            await waitUpTo(5) {
                copy.pasteboard.string(forType: .string)?.contains("COPYTASKMARKER") == true
            })
        // The handle must not outlive the build it
        // names, or `largeTextTask != nil` stops meaning "a build is
        // running."
        #expect(
            await waitUpTo(5) { copy.commands.largeTextTask == nil },
            "expected the handle to clear once the copy completed")
    }

    /// `largeTextTaskGeneration` is per-pane, but the
    /// pasteboard is one resource shared by every pane, every other app,
    /// and the child (OSC 52) — a slow copy finishing after something else
    /// has written more recently must not clobber it.
    @Test func copyDoesNotOverwriteAPasteboardWrittenToWhileItWasBuilding() async throws {
        let copy = try await makeHeldCopy()
        defer { copy.stop() }

        copy.commands.copy(nil)
        #expect(await waitUpTo(5) { copy.gate.entered.withLock { $0 } })

        // Someone else writes to the same pasteboard while the build is
        // parked — a second pane's own copy, in the shape this test can
        // actually produce without a second pane.
        let newerContent = "newer-\(UUID().uuidString)"
        copy.pasteboard.clearContents()
        copy.pasteboard.setString(newerContent, forType: .string)

        copy.gate.released.withLock { $0 = true }
        #expect(await waitUpTo(5) { copy.commands.largeTextTask == nil })

        // The stale build must not have overwritten the newer write.
        #expect(copy.pasteboard.string(forType: .string) == newerContent)
    }

    @Test func teardownCancelsAnInFlightLargeTextTask() async throws {
        let pane = makePane()
        let started = Mutex(false)
        let cancelled = Mutex(false)
        pane.commands.largeTextTask = Task {
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
        }
        #expect(await waitUpTo(2) { started.withLock { $0 } })

        pane.teardown()

        #expect(pane.commands.largeTextTask == nil)
        // `await Task.sleep`, not `Thread.sleep`: this test and the
        // in-flight task both run on the main actor, so blocking the
        // thread here would starve the task's own cancellation catch block
        // from ever getting to run — the same class of self-deadlock
        // `SessionLifecycleTests` documents.
        #expect(await waitUpTo(2) { cancelled.withLock { $0 } })
    }
}
