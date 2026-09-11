import AppKit
import Synchronization
import Testing

@testable import Corta
import CortaTerminal

/// B05: copy and export build their (potentially whole-scrollback) text off
/// the interaction path, sharing one cancellable `largeTextTask` handle.
///
/// `.serialized` and a real pane, like `SearchDebounceTests` — the text
/// under copy comes from a genuine shell.
@MainActor
@Suite(.serialized)
struct LargeTextTaskTests {
    private func makePane() -> ViewController {
        let pane = ViewController()
        _ = pane.view
        return pane
    }

    @MainActor
    private func waitUpTo(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func gridContains(_ pane: ViewController, _ needle: String) -> Bool {
        pane.session.snapshot().logicalLines().contains { $0.text.contains(needle) }
    }

    @Test func copyBuildsOffMainThreadAndLandsOnThePasteboard() async throws {
        let pane = makePane()
        defer { pane.teardown() }
        let session = try #require(pane.session)
        session.write(Array("echo COPYTASKMARKER\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "COPYTASKMARKER") })

        let grid = session.snapshot()
        // The whole document, same range ⌘A builds — simplest way to be
        // sure the marker is inside it regardless of exact row layout.
        pane.selection = TerminalSelection(
            start: GridPosition(row: -grid.scrollback.count, column: 0),
            end: GridPosition(row: grid.rows - 1, column: grid.columns - 1),
            baseScrollbackTotal: grid.scrollback.totalPushed)

        // A private pasteboard, not `.general` (the real system clipboard):
        // `pasteboardForTesting` (B05 review follow-up) is exactly the seam
        // `NativeIntegrationTests` already uses `.withUniqueName()` for, so
        // this never touches — and can never be raced by, or clobber — the
        // developer's own clipboard contents.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pane.pasteboardForTesting = pasteboard

        let markerBefore = "sentinel-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(markerBefore, forType: .string)

        // `Task.detached` gives no scheduling barrier — for a grid this
        // small, asserting "hasn't landed yet" immediately after `copy(_:)`
        // returns would pass or fail depending on how fast the scheduler
        // happens to run it, not on whether the build is actually
        // asynchronous. The gate makes that deterministic.
        let buildEntered = Mutex(false)
        let releaseBuild = Mutex(false)
        pane.largeTextBuildGateForTesting = {
            buildEntered.withLock { $0 = true }
            while !releaseBuild.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
        }

        pane.copy(nil)
        #expect(await waitUpTo(5) { buildEntered.withLock { $0 } })
        #expect(pasteboard.string(forType: .string) == markerBefore, "the build is parked before touching the pasteboard")
        #expect(pane.largeTextTask != nil)

        releaseBuild.withLock { $0 = true }

        #expect(
            await waitUpTo(5) {
                pasteboard.string(forType: .string)?.contains("COPYTASKMARKER") == true
            })
        // B05 review follow-up: the handle must not outlive the build it
        // names, or `largeTextTask != nil` stops meaning "a build is
        // running."
        #expect(
            await waitUpTo(5) { pane.largeTextTask == nil },
            "expected the handle to clear once the copy completed")
    }

    /// B05 review follow-up: `largeTextTaskGeneration` is per-pane, but the
    /// pasteboard is one resource shared by every pane, every other app,
    /// and the child (OSC 52) — a slow copy finishing after something else
    /// has written more recently must not clobber it.
    @Test func copyDoesNotOverwriteAPasteboardWrittenToWhileItWasBuilding() async throws {
        let pane = makePane()
        defer { pane.teardown() }
        let session = try #require(pane.session)
        session.write(Array("echo COPYTASKMARKER\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "COPYTASKMARKER") })

        let grid = session.snapshot()
        pane.selection = TerminalSelection(
            start: GridPosition(row: -grid.scrollback.count, column: 0),
            end: GridPosition(row: grid.rows - 1, column: grid.columns - 1),
            baseScrollbackTotal: grid.scrollback.totalPushed)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pane.pasteboardForTesting = pasteboard

        let buildEntered = Mutex(false)
        let releaseBuild = Mutex(false)
        pane.largeTextBuildGateForTesting = {
            buildEntered.withLock { $0 = true }
            while !releaseBuild.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
        }

        pane.copy(nil)
        #expect(await waitUpTo(5) { buildEntered.withLock { $0 } })

        // Someone else writes to the same pasteboard while the build is
        // parked — a second pane's own copy, in the shape this test can
        // actually produce without a second full pane.
        let newerContent = "newer-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(newerContent, forType: .string)

        releaseBuild.withLock { $0 = true }
        #expect(await waitUpTo(5) { pane.largeTextTask == nil })

        // The stale build must not have overwritten the newer write.
        #expect(pasteboard.string(forType: .string) == newerContent)
    }

    @Test func teardownCancelsAnInFlightLargeTextTask() async throws {
        let pane = makePane()
        let started = Mutex(false)
        let cancelled = Mutex(false)
        pane.largeTextTask = Task {
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
        }
        #expect(await waitUpTo(2) { started.withLock { $0 } })

        pane.teardown()

        #expect(pane.largeTextTask == nil)
        // `await Task.sleep`, not `Thread.sleep`: this test and the
        // in-flight task both run on the main actor, so blocking the
        // thread here would starve the task's own cancellation catch block
        // from ever getting to run — the same class of self-deadlock
        // `SessionLifecycleTests` documents.
        #expect(await waitUpTo(2) { cancelled.withLock { $0 } })
    }
}
