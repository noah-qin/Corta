import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

// P01: the write path is a bounded, ordered, cancellable queue drained by a
// serial writer queue — `write` itself only enqueues. These tests use the
// `writerSink` hook to gate and record outbound bytes deterministically;
// like `TerminalSessionTests` they wait on conditions, never on the clock,
// and the only deadlines are hang ceilings (see that suite's header).
@Suite(.serialized) struct TerminalSessionWriteQueueTests {
    /// Keyboard input and the parser's query replies share one FIFO: a DA1
    /// query fed to the reader between two user writes must reach the pty
    /// between those same two writes — before P01 the reply was written
    /// synchronously from the reader thread and could interleave with a
    /// main-thread `write` byte stream.
    @Test func userInputAndProtocolRepliesKeepTheirEnqueueOrder() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        let recorded = Mutex<[[UInt8]]>([])
        session.writerSink = { chunk in recorded.withLock { $0.append(chunk) } }

        // Feed exactly one primary-DA query (ESC [ c), then end of file —
        // but not before the first user write has been recorded. Without
        // that gate the reader races the test's own `write`, and which of
        // the two is enqueued first is a coin toss rather than the property
        // under test: this suite asserts that bytes *leave* in the order
        // they were enqueued, not that the test won the race to enqueue
        // first. Thread sanitizer changes the timing enough to lose that
        // race reliably, which is how the gap was found.
        let queryDelivered = Mutex(false)
        let mayDeliverQuery = Mutex(false)
        session.readerSource = ReaderSource(
            read: { buffer in
                // Waits rather than returning 0: a zero-length read is end
                // of file to the reader, which would stop it before the gate
                // ever opened. Bounded so a mistake here fails rather than
                // hangs.
                let deadline = ContinuousClock.now + .seconds(10)
                while !mayDeliverQuery.withLock({ $0 }), ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let already = queryDelivered.withLock { delivered -> Bool in
                    let was = delivered
                    delivered = true
                    return was
                }
                guard !already else { return 0 }
                let query: [UInt8] = [0x1B, 0x5B, 0x63]
                query.withUnsafeBytes { buffer.copyMemory(from: $0) }
                return query.count
            },
            isReadable: { false }
        )
        session.start()

        let userBefore: [UInt8] = [0x41]  // "A"
        session.write(userBefore)
        let firstDrained = awaitRecording(recorded, count: 1)
        #expect(firstDrained, "expected the first user write to drain")

        // Only now let the query through, so the reply is enqueued strictly
        // after the first user write and strictly before the second.
        mayDeliverQuery.withLock { $0 = true }

        // The reply is enqueued once the reader has fed the query; waiting
        // for it in the recorded stream is what orders the second user write
        // after the reply's enqueue, making the FIFO assertion meaningful.
        let replyWritten = awaitRecording(recorded, count: 2)
        #expect(replyWritten, "expected the DA reply to be written")
        let userAfter: [UInt8] = [0x42]  // "B"
        session.write(userAfter)
        let secondDrained = awaitRecording(recorded, count: 3)
        #expect(secondDrained, "expected the second user write to drain")

        let chunks = recorded.withLock { $0 }
        #expect(chunks.count == 3, "expected exactly input, reply, input; got \(chunks)")
        #expect(chunks[0] == userBefore)
        #expect(chunks[1].first == 0x1B, "expected the fixed-format DA reply; got \(chunks[1])")
        #expect(chunks[2] == userAfter)
    }

    /// `write` must not block behind a write that is itself stuck (a child
    /// that has stopped reading). The sink's gate parks the drain on the
    /// first chunk; the test thread then calling `write` again *returning at
    /// all* is the assertion — a synchronous implementation hangs here.
    @Test func writeDoesNotBlockBehindAStalledWrite() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        let gateOpen = Mutex(false)
        let sinkEntered = Mutex(false)
        let recorded = Mutex<[[UInt8]]>([])
        session.writerSink = { chunk in
            sinkEntered.withLock { $0 = true }
            while !gateOpen.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
            recorded.withLock { $0.append(chunk) }
        }
        session.start()

        let first: [UInt8] = [1, 1, 1]
        let second: [UInt8] = [2, 2, 2]
        session.write(first)
        #expect(
            awaitCondition { sinkEntered.withLock { $0 } },
            "precondition: the drain should be parked inside the gated sink")

        // Must return promptly even though the previous chunk is stuck.
        session.write(second)

        gateOpen.withLock { $0 = true }
        let bothDrained = awaitRecording(recorded, count: 2)
        #expect(bothDrained, "expected both writes to drain once unblocked")
        let chunks = recorded.withLock { $0 }
        #expect(chunks == [first, second])
    }

    /// Cancellation: `stop()` drops everything still queued. The drain is
    /// parked on chunk A by the gate; B is pending behind it and C is
    /// submitted after the stop — neither may ever reach the sink.
    @Test func stopDiscardsPendingWrites() throws {
        let session = try TerminalSession(executable: "/bin/cat")

        let gateOpen = Mutex(false)
        let sinkEntered = Mutex(false)
        let recorded = Mutex<[[UInt8]]>([])
        session.writerSink = { chunk in
            sinkEntered.withLock { $0 = true }
            while !gateOpen.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
            recorded.withLock { $0.append(chunk) }
        }
        session.start()

        let chunkA: [UInt8] = [0x0A]
        let chunkB: [UInt8] = [0x0B]
        let chunkC: [UInt8] = [0x0C]
        session.write(chunkA)
        #expect(
            awaitCondition { sinkEntered.withLock { $0 } },
            "precondition: the drain should be parked inside the gated sink")
        session.write(chunkB)

        session.stop()
        session.write(chunkC)  // rejected: the session is stopped
        gateOpen.withLock { $0 = true }

        // A was already inside the sink when stop ran, so it completes; B
        // was pending and C post-stopped, so the recorded stream can only
        // ever be [A] — wait for A, then assert nothing else arrived.
        let inflightCompleted = awaitRecording(recorded, count: 1)
        #expect(inflightCompleted, "expected the in-flight write to complete")
        let chunks = recorded.withLock { $0 }
        #expect(chunks == [chunkA], "stop must discard queued writes; got \(chunks)")
    }

    /// Back-pressure: the queue is bounded. With the drain parked, 1 MB
    /// chunks take the backlog past the 4 MB cap; the first chunk that
    /// arrives while the backlog already exceeds the cap is dropped —
    /// keyboard input is never buffered without bound.
    @Test func backlogBeyondTheCapIsDropped() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        let gateOpen = Mutex(false)
        let sinkEntered = Mutex(false)
        let recorded = Mutex<[[UInt8]]>([])
        session.writerSink = { chunk in
            sinkEntered.withLock { $0 = true }
            while !gateOpen.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
            recorded.withLock { $0.append(chunk) }
        }
        session.start()

        let megabyte = 1024 * 1024
        let chunks = (0..<7).map { UInt8($0) }.map { byte in
            [UInt8](repeating: byte, count: megabyte)
        }
        session.write(chunks[0])
        #expect(
            awaitCondition { sinkEntered.withLock { $0 } },
            "precondition: the drain should be parked inside the gated sink")
        for chunk in chunks.dropFirst() {
            session.write(chunk)
        }

        gateOpen.withLock { $0 = true }
        // Accepted: one chunk in flight inside the sink plus five queued —
        // the sixth queued write arrives when the backlog is 5 MB, already
        // past the 4 MB cap, so the seventh chunk is the one dropped. It can
        // never drain, so waiting for six is the hang-ceiling check and the
        // recorded content is the assertion. Compare by marker byte, not by
        // value equality — a failure should not dump megabytes of payload.
        let acceptedDrained = awaitRecording(recorded, count: 6)
        #expect(acceptedDrained, "expected the accepted writes to drain")
        let markers = recorded.withLock { $0.map { $0.first ?? 0xFF } }
        #expect(
            markers == [0, 1, 2, 3, 4, 5],
            "the seventh chunk arrives with a 6 MB backlog and must be dropped; drained markers: \(markers)")
    }

    /// End to end, with the real pty as the sink: queued writes reach the
    /// child in FIFO order.
    @Test func queuedWritesReachTheChildInOrder() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }
        session.start()

        session.write(Array("AAA\n".utf8))
        session.write(Array("BBB\n".utf8))
        session.write(Array("CCC\n".utf8))

        let dump = awaitGrid(session) {
            $0.contains("AAA") && $0.contains("BBB") && $0.contains("CCC")
        }
        guard let indexA = dump.range(of: "AAA"),
              let indexB = dump.range(of: "BBB"),
              let indexC = dump.range(of: "CCC")
        else {
            Issue.record("expected all three markers echoed; grid held:\n\(dump)")
            return
        }
        #expect(
            indexA.lowerBound < indexB.lowerBound && indexB.lowerBound < indexC.lowerBound,
            "expected the markers echoed in write order; grid held:\n\(dump)")
    }

    // MARK: - Condition waiting (see TerminalSessionTests' header)

    private func awaitCondition(
        timeout: Duration = .seconds(30),
        until condition: () -> Bool
    ) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func awaitRecording(
        _ recorded: borrowing Mutex<[[UInt8]]>, count: Int,
        timeout: Duration = .seconds(30)
    ) -> Bool {
        awaitCondition(timeout: timeout) { recorded.withLock { $0.count } >= count }
    }

    private func awaitGrid(
        _ session: TerminalSession, timeout: Duration = .seconds(30),
        until condition: (String) -> Bool
    ) -> String {
        let deadline = ContinuousClock.now + timeout
        var dump = session.snapshot().dump()
        while !condition(dump), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            dump = session.snapshot().dump()
        }
        return dump
    }
}
