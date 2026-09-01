import Foundation
import Testing

@testable import CortaTerminal

/// M0.1 — the package exists to escape `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` (`DESIGN.md` §2.2). These tests fail if that ever regresses.
@Suite("Package isolation")
struct PackageIsolationTests {
    /// Nonisolated by default: a plain class, mutated on both sides of a
    /// suspension point, with no actor hop and no concurrency diagnostic.
    /// Under default `MainActor` isolation this type would be main-actor
    /// bound and every use of it would hop.
    final class Cursor {
        var row = 0
        func advance() { row += 1 }
    }

    @Test("mutable state survives an await without isolation")
    func mutableStateSurvivesAnAwait() async {
        let cursor = Cursor()
        cursor.advance()
        await Task.yield()
        cursor.advance()
        #expect(cursor.row == 2)
    }

    /// The observable consequence: this code does not run on the main thread.
    /// If the module defaulted to `@MainActor`, swift-testing would hop the
    /// test body onto the main actor and this would fail.
    @Test("test bodies do not run on the main actor")
    func testBodiesAreNotMainActorIsolated() {
        #expect(!Thread.isMainThread)
    }

    /// The core's own types are usable from a detached, nonisolated context.
    @Test("core types are reachable off the main actor")
    func coreTypesAreReachableOffTheMainActor() async {
        let size = await Task.detached { TerminalSize(rows: 24, columns: 80) }.value
        #expect(size.rows == 24)
        #expect(size.columns == 80)
    }
}
