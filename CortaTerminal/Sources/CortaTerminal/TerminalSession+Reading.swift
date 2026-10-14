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

import CortaPOSIX
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Reading: runs on `readerThread` only.
extension TerminalSession {
    func runReaderLoop() {
        let source = readerSource ?? liveReaderSource
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.readChunkSize, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        var batch = [UInt8]()
        batch.reserveCapacity(Self.batchByteCap)

        while !stopped.withLock({ $0 }) {
            applyReaderPriority()
            // Between batches too: a flood is mostly single-slice batches.
            yieldToStateWaiters()
            batch.removeAll(keepingCapacity: true)
            let reachedEOF = readBatch(into: &batch, from: source, through: buffer)
            applyReaderPriority()
            if !batch.isEmpty { apply(batch) }
            if reachedEOF { break }
        }
        finishReading()
    }

    /// Reads until a batch is full, a read comes up short, or nothing more
    /// is ready. Returns whether the stream ended.
    private func readBatch(
        into batch: inout [UInt8], from source: ReaderSource, through buffer: UnsafeMutableRawBufferPointer
    ) -> Bool {
        while batch.count < Self.batchByteCap {
            let read: Int
            do {
                read = try source.read(buffer)
            } catch {
                reportIOFailure(error, operation: .read)
                return true
            }
            if read == 0 { return true }
            batch.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[..<read]))
            if read < Self.readChunkSize { return false }
            // Ask readiness rather than block: an exact chunk-multiple burst
            // would otherwise sit unapplied until the child speaks again.
            if !source.isReadable() { return false }
        }
        return false
    }

    /// Feeds one batch to the terminal under the lock, in slices, so a
    /// snapshot or resize never waits behind a whole batch; then sends the
    /// replies, arms a `?2026` timeout for a new episode and signals output.
    private func apply(_ batch: [UInt8]) {
        var responses: [UInt8] = []
        var episode: Int?
        var offset = 0
        while offset < batch.count {
            let end = min(offset + Self.feedLockSliceSize, batch.count)
            let slice = batch[offset..<end]
            let applied = state.withLock { current -> (responses: [UInt8], episode: Int?, compress: Bool) in
                let episodeBefore = current.terminal.synchronizedOutputEpisode
                current.terminal.feed(slice)
                reportImageBytes(current.terminal)
                let sliceResponses = current.terminal.takeOutput()
                // Rising edges, so DECRST+BSU in one batch arms a fresh timeout.
                // A repeated BSU does not extend it, or a child that never sends
                // ESU could stall presentation forever.
                let episodeAfter = current.terminal.synchronizedOutputEpisode
                // An integer compare: a pass is queued only once a batch seals.
                let compress = current.terminal.hasCompressionWork
                guard episodeAfter != episodeBefore else { return (sliceResponses, nil, compress) }
                current.synchronizedOutputEpisode = episodeAfter
                return (sliceResponses, episodeAfter, compress)
            }
            if responses.count + applied.responses.count <= Self.maxResponseBytesPerBatch {
                responses.append(contentsOf: applied.responses)
            }
            if let newEpisode = applied.episode { episode = newEpisode }
            offset = end
            if applied.compress { scheduleCompression() }
            // After the last slice too: the next batch's first slice is
            // one `read(2)` away, sooner than a waiter's wake, so a flood
            // of one-slice batches would never leave a gap.
            yieldToStateWaiters()
        }
        // Fixed-format only (`SECURITY.md` §2.1); same queue as input.
        if !responses.isEmpty {
            enqueueWrite([responses])
        }
        if let episode {
            scheduleSynchronizedOutputTimeout(episode: episode)
        }
        callbacks.withLock { $0.onOutput }?()
    }

    /// After the last read: ends a `?2026` episode the dead child never
    /// will, then reports how the child ended — or why it cannot be known.
    private func finishReading() {
        let clearedSync = state.withLock { current -> Bool in
            guard current.terminal.isSynchronizedOutputEnabled else { return false }
            current.terminal.endSynchronizedOutput()
            return true
        }
        if clearedSync {
            callbacks.withLock { $0.onOutput }?()
        }

        // An I/O fault is not child exit. Report it immediately rather than
        // park here for ten seconds and silently lose the only reader.
        guard ioFailure == nil else { return }
        var exit = pty.waitForExit(timeout: hangupGracePeriod)
        if exit == nil, !stopped.withLock({ $0 }) {
            // End of file, and the child lives on: it gave up its terminal
            // (`TIOCNOTTY`) and closed it. Nothing it does reaches this pane
            // again, and no exit is coming to say so — offer recovery.
            reportIOFailure(PTYError.ioFailed(code: ENXIO), operation: .read)
            return
        }
        if exit == nil, stopped.withLock({ $0 }) {
            // Closed, and the group ignored `SIGHUP` (`trap '' HUP`, a daemon
            // that kept the terminal): closing a pane stops what was in it
            // (`SECURITY.md` §4.4). Left alone it ran on with no terminal,
            // and nothing was left to reap it once it did exit. Only this
            // group: a job the shell put in its own is not this pane's to end.
            pty.signalProcessGroup(SIGKILL)
            exit = pty.waitForExit(timeout: .seconds(2))
        }
        if let exit {
            let callback = callbacks.withLock { state -> (@Sendable (ProcessExit) -> Void)? in
                state.childExit = exit
                return state.onChildExit
            }
            callback?(exit)
        }
    }

    private var liveReaderSource: ReaderSource {
        ReaderSource(
            read: { [pty] buffer in
                // close() explicitly wakes this wait, even for a silent child
                // that ignores hangup. No timer wakes an idle reader.
                while true {
                    if try pty.waitUntilReadable(timeoutMilliseconds: -1) {
                        return try pty.read(into: buffer)
                    }
                }
            },
            isReadable: { [pty] in
                // Any revents count; the read observes end of file.
                (try? pty.waitUntilReadable(timeoutMilliseconds: 0)) ?? true
            }
        )
    }

    /// Ends a `?2026` episode the child never closes, unless a later episode
    /// has begun.
    private func scheduleSynchronizedOutputTimeout(episode: Int) {
        let expire: @Sendable () -> Void = { [self] in
            let ended = state.withLock { current -> Bool in
                guard current.synchronizedOutputEpisode == episode,
                      current.terminal.isSynchronizedOutputEnabled
                else { return false }
                current.terminal.endSynchronizedOutput()
                return true
            }
            if ended {
                callbacks.withLock { $0.onOutput }?()
            }
        }
        if let scheduleTimeout {
            scheduleTimeout(synchronizedOutputTimeout, expire)
        } else {
            syncTimeoutQueue.asyncAfter(
                deadline: DispatchTime.now() + synchronizedOutputTimeout.dispatchInterval, execute: expire)
        }
    }

    /// Under `state`'s lock. Not after `stop()`: a last slice racing it would
    /// charge the shared budget again for a pane that is gone.
    func reportImageBytes(_ terminal: Terminal) {
        guard let imageBudget else { return }
        // Most slices hold no image: skip the shared lock unless the figure moved.
        let bytes = terminal.retainedImageBytes
        guard bytes != reportedImageBytes.withLock({ $0 }), !stopped.withLock({ $0 }) else { return }
        reportedImageBytes.withLock { $0 = bytes }
        imageBudget.report(bytes, for: ObjectIdentifier(self))
    }
}
