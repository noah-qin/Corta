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

import Darwin
import Foundation
import Synchronization
import Testing
@testable import CortaSFTP

/// One bidirectional in-memory channel.
final class SFTPLoopbackConnection: @unchecked Sendable {
    /// Reads block up to this long before failing, so a broken test fails
    /// instead of hanging the suite.
    ///
    /// The pipe is idle whenever the peer is simply busy — a test awaiting
    /// something else, the engine backing off before a reconnect — so this
    /// has to be generous, and it scales with `CORTA_TEST_TIMEOUT_SCALE`
    /// like every other ceiling (`testTimeout`): under a sanitizer the
    /// suite is an order of magnitude slower and shares a few cores, and
    /// at a fixed 10 seconds the nightly sanitizer job failed every run
    /// from 2026-09-15 on — an idle server read timed out, the fake server
    /// closed the connection, and the client saw `connectionLost` in the
    /// middle of a transfer that was fine. Only a genuinely stuck test
    /// ever waits this out.
    static var readDeadline: TimeInterval { testTimeoutInterval(30) }

    private struct Side {
        var buffer: [UInt8] = []
    }

    private struct State {
        var clientToServer = Side()
        var serverToClient = Side()
        var isClosed = false
    }

    private let condition = NSCondition()
    private var state = State()

    /// The client's end of the channel, for `SFTPSession`.
    func clientTransport() -> Transport { Transport(connection: self, isClientSide: true) }
    /// The server's end, for `FakeSFTPServer`.
    func serverTransport() -> Transport { Transport(connection: self, isClientSide: false) }

    fileprivate func write(_ bytes: [UInt8], fromClient: Bool) throws(SFTPTransportError) {
        condition.lock()
        defer { condition.unlock() }
        guard !state.isClosed else { throw .closed }
        if fromClient {
            state.clientToServer.buffer.append(contentsOf: bytes)
        } else {
            state.serverToClient.buffer.append(contentsOf: bytes)
        }
        condition.broadcast()
    }

    fileprivate func read(into out: UnsafeMutableRawBufferPointer, fromClient: Bool) throws(SFTPTransportError) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        while true {
            let side = fromClient ? state.serverToClient : state.clientToServer
            // Buffered bytes are delivered even after close: a peer that
            // wrote a reply and then died still said it. EOF is closed
            // *and* drained.
            if !side.buffer.isEmpty {
                let count = min(out.count, side.buffer.count)
                side.buffer.withUnsafeBufferPointer { buffer in
                    out.copyMemory(
                        from: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count))
                }
                if fromClient {
                    state.serverToClient.buffer.removeFirst(count)
                } else {
                    state.clientToServer.buffer.removeFirst(count)
                }
                return count
            }
            if state.isClosed { return 0 }
            if !condition.wait(until: deadline) {
                throw .ioFailed(code: ETIMEDOUT)
            }
        }
    }

    func close() {
        condition.lock()
        state.isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    final class Transport: SFTPChannelTransport, @unchecked Sendable {
        let connection: SFTPLoopbackConnection
        let isClientSide: Bool

        init(connection: SFTPLoopbackConnection, isClientSide: Bool) {
            self.connection = connection
            self.isClientSide = isClientSide
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws(SFTPTransportError) -> Int {
            try connection.read(into: buffer, fromClient: isClientSide)
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError) {
            try connection.write(Array(bytes), fromClient: isClientSide)
        }

        func close() {
            connection.close()
        }
    }
}
