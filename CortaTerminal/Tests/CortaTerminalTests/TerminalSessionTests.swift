import Foundation
import Testing

@testable import CortaTerminal

// `.serialized`: every test here forks a real child process, and `fork()`
// in a heavily multithreaded process carries a real, if small, per-call
// risk (see `Spawn.swift`'s `forkLockStorage` comment) that scales with how
// many threads are doing how much concurrently. Running this suite's own
// spawns one at a time removes this suite's contribution to that risk
// during a parallel test run; it does not eliminate the underlying hazard.
@Suite(.serialized) struct TerminalSessionTests {
    @Test func readsChildOutputIntoTheGrid() throws {
        let session = try TerminalSession(executable: "/bin/echo", arguments: ["hello"])
        defer { session.stop() }

        // A generous budget, not a tight one: under a parallel test run
        // sharing the machine with other spawns (including this file's own
        // 100 MB `cat`), scheduling this child promptly is not guaranteed.
        var text = ""
        for _ in 0..<1_000 {
            text = session.snapshot().dump()
            if text.contains("hello") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(text.contains("hello"))
    }

    @Test func floodDoesNotHangTheReaderLoop() throws {
        // `yes` floods output; the reader thread must keep draining it
        // without the batch cap ever hanging (`PERFORMANCE.md` §2.1).
        let session = try TerminalSession(executable: "/usr/bin/yes")
        defer { session.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        let text = session.snapshot().dump()
        #expect(text.contains("y"))
    }

    @Test func catOfALargeFileDoesNotStallTheChild() throws {
        // M1.19's other done-when: `cat` of a 100 MB file must not stall —
        // the reader thread has to keep draining even though the scrollback
        // (10,000 lines by default) evicts almost everything it reads.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-cat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: path) }

        let line = String(repeating: "x", count: 199) + "\n"
        let lineBytes = Array(line.utf8)
        let targetBytes = 100 * 1024 * 1024
        let lineCount = targetBytes / lineBytes.count
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        for _ in 0..<lineCount { handle.write(Data(lineBytes)) }
        try handle.close()

        let session = try TerminalSession(executable: "/bin/cat", arguments: [path.path])
        defer { session.stop() }

        let exit = session.pty.waitForExit(timeout: .seconds(30))
        #expect(exit != nil, "cat of a 100 MB file should finish well within 30s if the reader never stalls it")
    }

    @Test func controlCStopsAFloodingChild() throws {
        // The other half of M1.19's `yes` scenario: even while the reader
        // thread is draining a flood as fast as it can, writing ETX must
        // still reach the pty's line discipline and signal the child — the
        // write path is never blocked behind the read path.
        let session = try TerminalSession(executable: "/usr/bin/yes")
        defer { session.stop() }

        Thread.sleep(forTimeInterval: 0.1)
        session.write([0x03])

        let exit = session.pty.waitForExit(timeout: .seconds(5))
        #expect(exit != nil, "^C should terminate a flooding child within 5s")
    }

    @Test func writeDeliversBytesToTheChild() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        session.write(Array("hi\n".utf8))

        var text = ""
        for _ in 0..<1_000 {
            text = session.snapshot().dump()
            if text.contains("hi") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(text.contains("hi"))
    }
}
