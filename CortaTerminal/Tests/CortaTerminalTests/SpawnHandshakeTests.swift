import Darwin
import Foundation
import Testing

@testable import CortaTerminal

/// E04 — the `corta-exec` handshake: bounded, `EINTR`-tolerant, fully
/// decoded. The pipe tests drive `readHelperStatus` directly; only the last
/// test spawns a real child (hence `.serialized`).
@Suite(.serialized) struct SpawnHandshakeTests {
    @Test func decodesAFullErrnoStatus() throws {
        let ends = try makePipe()
        defer { close(ends.read) }

        var code: Int32 = ENOENT
        withUnsafeBytes(of: &code) { bytes in
            #expect(Darwin.write(ends.write, bytes.baseAddress, bytes.count) == bytes.count)
        }
        close(ends.write)

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: ContinuousClock.now + .seconds(5))
        #expect(status == .execFailed(code: ENOENT))
    }

    @Test func cleanEOFSignalsExecSuccess() throws {
        let ends = try makePipe()
        defer { close(ends.read) }
        close(ends.write)  // FD_CLOEXEC closing on a successful execve

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: ContinuousClock.now + .seconds(5))
        #expect(status == .execSucceeded)
    }

    @Test func truncatedStatusIsReported() throws {
        let ends = try makePipe()
        defer { close(ends.read) }

        var partial: (UInt8, UInt8) = (0x02, 0x00)
        withUnsafeBytes(of: &partial) { bytes in
            #expect(Darwin.write(ends.write, bytes.baseAddress, bytes.count) == bytes.count)
        }
        close(ends.write)

        let status = Spawn.readHelperStatus(
            from: ends.read, deadline: ContinuousClock.now + .seconds(5))
        #expect(status == .truncated)
    }

    @Test func stalledHelperHitsTheDeadlineInsteadOfBlocking() throws {
        let ends = try makePipe()
        // The write end stays open past the deadline, as a wedged helper
        // would leave it.
        defer { close(ends.write) }
        defer { close(ends.read) }

        let deadline = ContinuousClock.now + .milliseconds(200)
        let status = Spawn.readHelperStatus(from: ends.read, deadline: deadline)
        #expect(status == .timedOut)
        #expect(ContinuousClock.now < deadline + .seconds(5))
    }

    @Test func failedExecReportsTheHelpersErrno() throws {
        // End to end: `corta-exec` fails the execve, writes ENOENT, and
        // `Spawn.child` throws it (and reaps the helper — E04).
        #expect(throws: PTYError.spawnFailed(code: ENOENT)) {
            try PTY.spawn(executable: "/nonexistent/corta-does-not-exist")
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            Issue.record("pipe() failed: errno \(errno)")
            throw PTYError.openFailed(code: errno)
        }
        return (fds[0], fds[1])
    }
}
