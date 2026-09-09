import AppKit
import Testing

@testable import Corta
@testable import CortaTerminal

/// P04 — the keystroke search path: the sweep is debounced, runs off the
/// main thread, a newer query supersedes the one in flight, and closing the
/// bar cancels it. Real panes with real children, like
/// `PaneTeardownTests` — the content under search comes from the shell
/// itself, so the whole path (PTY → grid → snapshot → sweep → apply) is
/// exercised rather than a mock of it.
@MainActor
@Suite(.serialized)
struct SearchDebounceTests {
    /// Loads the pane's view, which builds the renderer and spawns the child
    /// exactly as a window would.
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

    private func makePaneWithMarker() async throws -> ViewController {
        let pane = makePane()
        let session = try #require(pane.session)
        session.write(Array("echo P04MARKER\n".utf8))
        #expect(await waitUpTo(10) { self.gridContains(pane, "P04MARKER") })
        return pane
    }

    @Test func keystrokeSearchDebouncesThenDelivers() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        // Debounced and detached: nothing can have landed on the same
        // main-actor turn that scheduled the sweep.
        #expect(pane.searchMatches.isEmpty)
        #expect(pane.searchTask != nil)

        #expect(await waitUpTo(5) { !pane.searchMatches.isEmpty })
        #expect(pane.searchTask == nil)
    }

    @Test func aNewerQuerySupersedesTheInFlightSweep() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        // Retyped before the debounce elapses: the first sweep is cancelled
        // in its sleep and only the newest query may land.
        field.stringValue = "zzz-no-such-string"
        pane.updateSearchResults(scrollsToMatch: true)

        #expect(await waitUpTo(5) { pane.searchTask == nil })
        #expect(pane.searchMatches.isEmpty)
    }

    @Test func closingTheBarCancelsTheInFlightSweep() async throws {
        let pane = try await makePaneWithMarker()
        defer { pane.teardown() }

        pane.showSearchBar()
        let field = try #require(pane.searchField)
        field.stringValue = "P04MARKER"
        pane.updateSearchResults(scrollsToMatch: true)
        #expect(pane.searchTask != nil)

        pane.closeSearchBar()
        #expect(pane.searchTask == nil)
        #expect(pane.searchMatches.isEmpty)
    }
}
