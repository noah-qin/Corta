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

        let pasteboard = NSPasteboard.general
        let markerBefore = "sentinel-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(markerBefore, forType: .string)

        pane.copy(nil)
        // Returns before the pasteboard write: the build is asynchronous,
        // so immediately after the call the old sentinel is still there.
        #expect(pasteboard.string(forType: .string) == markerBefore)
        #expect(pane.largeTextTask != nil)

        #expect(
            await waitUpTo(5) {
                pasteboard.string(forType: .string)?.contains("COPYTASKMARKER") == true
            })
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
