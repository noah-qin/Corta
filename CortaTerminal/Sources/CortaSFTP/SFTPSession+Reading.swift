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

extension SFTPSession {
    // MARK: - Reader loop

    /// Runs on the dedicated reader thread: frame in, dispatch, repeat.
    /// Any failure — EOF, a transport error, an undecodable frame, a reply
    /// to an unknown id — ends the session, because after any of them the
    /// byte stream can no longer be trusted to align with requests.
    func readerLoop() {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        while true {
            do {
                guard try readExact(&lengthBytes) else {
                    tearDown(with: .transport(.connectionLost), closingTransport: false)
                    return
                }
                let length = (UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16)
                    | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3])
                let frameLength = try SFTPCodec.validateFrameLength(length)
                var frame = [UInt8](repeating: 0, count: frameLength)
                guard try readExact(&frame) else {
                    tearDown(with: .transport(.connectionLost), closingTransport: false)
                    return
                }
                let message = try SFTPCodec.decodeFrame(frame)
                dispatch(message)
            } catch let error as SFTPCodecError {
                tearDown(
                    with: .protocolViolation("undecodable frame: \(error)"),
                    closingTransport: true)
                return
            } catch let error as SFTPTransportError {
                tearDown(with: .transport(error), closingTransport: false)
                return
            } catch let error as SFTPError {
                tearDown(with: error, closingTransport: true)
                return
            } catch {
                tearDown(with: .protocolViolation("\(error)"), closingTransport: true)
                return
            }
        }
    }

    /// Reads exactly `buffer.count` bytes. Returns false at EOF before
    /// the first byte of this read; EOF part-way through a frame is a
    /// lost connection, thrown as such.
    private func readExact(_ buffer: inout [UInt8]) throws -> Bool {
        var filled = 0
        while filled < buffer.count {
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return try transport.read(
                    into: UnsafeMutableRawBufferPointer(start: base + filled, count: raw.count - filled))
            }
            if count == 0 {
                if filled == 0 { return false }
                throw SFTPTransportError.connectionLost
            }
            filled += count
        }
        return true
    }

    /// Routes one decoded message to its waiter.
    private func dispatch(_ message: SFTPMessage) {
        if case .version = message.payload {
            finishHandshake(.success(message))
            return
        }
        let resolved = state.withLock { state -> (
            continuation: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>?,
            wasCancelled: Bool,
            unknown: Bool
        ) in
            if let entry = state.inFlight.removeValue(forKey: message.requestID) {
                releaseWindowSlot(&state)
                state.ids.resolved(entry.ticket)
                return (entry.continuation, false, false)
            }
            if state.ids.acceptLateReply(message.requestID) {
                // The late reply to a cancelled request: swallow it, and
                // only now is the id safe to recycle.
                return (nil, true, false)
            }
            return (nil, false, true)
        }
        if let continuation = resolved.continuation {
            continuation.resume(returning: .success(message))
        } else if resolved.unknown {
            tearDown(
                with: .protocolViolation(
                    "a reply arrived for request-id \(message.requestID), which nothing sent"),
                closingTransport: true)
        }
    }

    // MARK: - Response mapping

    func attributesRequest(
        _ payload: @escaping (UInt32) -> SFTPPayload
    ) async throws(SFTPError) -> SFTPAttributes {
        let reply = try await request(payload)
        guard case .attrs(let attributes) = reply.payload else {
            throw unexpected(reply, wanted: "ATTRS")
        }
        return attributes
    }

    /// Voids a reply that should be STATUS-OK; any other STATUS is the
    /// server's definitive answer to the request.
    func expectOK(_ reply: SFTPMessage) throws(SFTPError) {
        switch reply.payload {
        case .status(let status):
            if status.code == .ok { return }
            throw .server(status)
        default:
            throw unexpected(reply, wanted: "STATUS")
        }
    }

    func unexpected(_ reply: SFTPMessage, wanted: String) -> SFTPError {
        // A STATUS payload here is the server declining the request —
        // surface it as the server's answer, not as framing trouble.
        if case .status(let status) = reply.payload {
            return .server(status)
        }
        return .protocolViolation("expected \(wanted), got message type \(reply.type)")
    }
}
