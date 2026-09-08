import AppKit
import Darwin
import Testing

@testable import Corta
import CortaTerminal

/// E01 — every close path (pane, window, quit) must run the same explicit,
/// idempotent teardown: `TerminalSession.deinit` cannot be relied on because
/// the reader thread retains the session until its loop exits.
///
/// `.serialized` and real children, for the same reasons as the core's
/// `TerminalSessionLifecycleTests`: each pane spawns a genuine `zsh -l`, and
/// the assertions are against real PIDs, file descriptors and Mach threads
/// of the test-host process.
@MainActor
@Suite(.serialized)
struct PaneTeardownTests {
    /// Loads the pane's view, which builds the renderer and spawns the child
    /// exactly as a window would.
    private func makePane() -> ViewController {
        let pane = ViewController()
        _ = pane.view
        return pane
    }

    @Test func teardownTerminatesTheChildProcess() throws {
        let pane = makePane()
        let session = try #require(pane.session)
        let pid = session.pty.processIdentifier
        #expect(kill(pid, 0) == 0, "the child should be alive before teardown")

        pane.teardown()

        #expect(
            session.pty.waitForExit(timeout: .seconds(10)) != nil,
            "teardown must let the child be reaped")
        #expect(
            kill(pid, 0) == -1 && errno == ESRCH,
            "the child PID must be gone after teardown, not merely signalled")
    }

    @Test func teardownIsIdempotent() throws {
        let pane = makePane()
        let session = try #require(pane.session)
        let pid = session.pty.processIdentifier

        pane.teardown()
        // A pane can be reached by two close paths (its own `closePane` and
        // its window's close); the second pass must be a no-op.
        pane.teardown()

        #expect(session.pty.waitForExit(timeout: .seconds(10)) != nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func closingASplitPaneTearsDownItsSession() throws {
        let split = SplitViewController()
        _ = split.view
        let first = try #require(split.panes.first)
        split.splitFocusedPane(orientation: .columns)
        let second = try #require(split.panes.first { $0 !== first })
        let session = try #require(second.session)
        let pid = session.pty.processIdentifier

        split.closePane(second)

        #expect(session.pty.waitForExit(timeout: .seconds(10)) != nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        // The surviving pane is untouched.
        #expect(first.session != nil)
        #expect(kill(first.session.pty.processIdentifier, 0) == 0)
        first.teardown()
    }

    @Test func windowTeardownStopsEveryPane() throws {
        let split = SplitViewController()
        _ = split.view
        split.splitFocusedPane(orientation: .rows)
        let sessions = split.panes.compactMap(\.session)
        #expect(sessions.count == 2)

        split.teardown()

        for session in sessions {
            #expect(
                session.pty.waitForExit(timeout: .seconds(10)) != nil,
                "every pane's child must be reaped by the window-level teardown")
        }
    }

    @Test func teardownRecoversFileDescriptorsAndThreads() throws {
        // Baselines include the test host's own windows and their sessions;
        // only the delta this pane adds and then returns matters.
        let baselineFDs = Self.openFileDescriptorCount()
        let baselineThreads = Self.threadCount()

        let pane = makePane()
        let session = try #require(pane.session)

        pane.teardown()
        #expect(session.pty.waitForExit(timeout: .seconds(10)) != nil)

        // The PTY master closes synchronously in `stop()`; the reader thread
        // exits once its blocked read observes the closed descriptor, so both
        // are polled rather than read once. GCD keeps spare worker threads
        // around, so the thread check allows one of slack — a leaked reader
        // thread still trips it once the host's own baseline has settled.
        let recovered = waitUntilTrue(timeout: .seconds(10)) {
            Self.openFileDescriptorCount() <= baselineFDs
                && Self.threadCount() <= baselineThreads + 1
        }
        let fdCount = Self.openFileDescriptorCount()
        let threads = Self.threadCount()
        #expect(
            recovered,
            "teardown must return the PTY descriptor and the reader thread; baselines fds=\(baselineFDs) threads=\(baselineThreads), now fds=\(fdCount) threads=\(threads)")
    }

    private func waitUntilTrue(
        timeout: Duration, _ condition: () -> Bool
    ) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private static func openFileDescriptorCount() -> Int {
        let byteCount = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return 0 }
        return Int(byteCount) / MemoryLayout<proc_fdinfo>.size
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads
        else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: threads),
                vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.stride))
        }
        return Int(count)
    }
}

