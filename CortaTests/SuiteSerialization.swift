import Foundation
import Testing

/// Holds whole suites against each other.
///
/// `.serialized` orders the tests *inside* one suite; it does nothing about
/// two suites running at the same time, which is what a full `CortaTests` run
/// does by default. Some state is shared across suite boundaries and has to
/// be held anyway:
///
/// - **`.metalSerialized`** — `GlyphAtlas` is single-threaded by design, and
///   a full parallel run aborted the runner in `ColorEmojiRenderTests` with a
///   texture descriptor Metal refused (T07). Nothing reproduced it in
///   isolation; the suites that build an atlas now take turns.
/// - **`.sessionRestoreSerialized`** — `SessionRestore.directory` is a
///   mutable static, opened up for exactly this reason. Two suites point it
///   at their own temporary directory and put it back afterwards, so with
///   both running at once one suite reads the other's fixture, or restores a
///   value the other had already replaced. Today both are `@MainActor` with
///   fully synchronous bodies, which is what has kept them apart so far — an
///   `await` added anywhere inside either one would end that silently. The
///   gate states the requirement instead of leaving it to be rediscovered.
///
/// Applied alongside `.serialized`, not instead of it: `@Suite(.serialized,
/// .metalSerialized)`.
struct SuiteSerializationTrait: SuiteTrait, TestTrait, TestScoping {

    let gate: SuiteGate

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // The scope is provided once for the suite and again for each of its
        // cases. Taking the gate for the suite itself would hold it for the
        // suite's whole run and deadlock against the suite's own cases.
        guard testCase != nil else {
            try await function()
            return
        }
        await gate.acquire()
        do {
            try await function()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }
}

extension Trait where Self == SuiteSerializationTrait {
    /// See `SuiteSerializationTrait`.
    static var metalSerialized: Self { Self(gate: .metal) }
    /// See `SuiteSerializationTrait`.
    static var sessionRestoreSerialized: Self { Self(gate: .sessionRestore) }
}

/// A one-holder gate per kind of shared state. Not a lock: the scope it
/// guards contains `await`, and blocking a cooperative thread there would
/// stall the pool rather than order it.
actor SuiteGate {
    static let metal = SuiteGate()
    static let sessionRestore = SuiteGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
