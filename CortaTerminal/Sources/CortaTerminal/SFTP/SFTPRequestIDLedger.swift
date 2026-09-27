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

/// The request-id lifecycle, as a value so every ordering is testable — in
/// the session, the windows these rules turn on (between a continuation
/// resuming and a cancellation handler uninstalling) cannot be driven.
///
/// An id is reused only once nothing can still arrive for it:
///
/// - **A reply the server still owes.** Cancelled while registered: the
///   waiter is resumed, but the reply is coming, so the id waits in
///   `awaitingLateReply` or the reply would be read as the next request's.
/// - **A registration not yet made.** Cancelled before registering: the
///   refusal waits for that registration. Recycling the id instead handed
///   the refusal to the next sender, which then failed without sending —
///   the missing CLOSE after an aborted download.
/// - **Nothing.** `withTaskCancellationHandler` can run after the operation
///   completes; a cancellation for an id already resolved owes no refusal,
///   and marking one would refuse an unrelated send.
///
/// **An id is not a request**: ids are reissued, so a cancellation naming
/// only an id lands on whoever holds it now. Each allocation carries a
/// generation, and a stale handler compares unequal and does nothing.
struct SFTPRequestIDLedger {
    /// One allocation; the id alone is only what goes on the wire.
    struct Ticket: Hashable, Sendable {
        let id: UInt32
        let generation: UInt64
    }

    /// Wraps safely: the window bounds how many ids are live.
    private var nextID: UInt32 = 0

    /// Recycled ids nothing can still arrive for, LIFO.
    private var free: [UInt32] = []

    private var nextGeneration: UInt64 = 0

    /// The live generation of each id that is out.
    private var outstanding: [UInt32: UInt64] = [:]

    private var awaitingLateReply: Set<UInt32> = []

    private var refuseOnRegistration: Set<Ticket> = []

    mutating func allocate() -> Ticket {
        let id: UInt32
        if let recycled = free.popLast() {
            id = recycled
        } else {
            id = nextID
            nextID &+= 1
        }
        let ticket = Ticket(id: id, generation: nextGeneration)
        nextGeneration &+= 1
        outstanding[id] = ticket.generation
        return ticket
    }

    /// `false`: this allocation was cancelled before registering; the id is
    /// recycled and nothing may be sent.
    mutating func register(_ ticket: Ticket) -> Bool {
        guard refuseOnRegistration.remove(ticket) != nil else { return true }
        resolve(ticket)
        return false
    }

    /// A reply arrived, or the write failed.
    mutating func resolved(_ ticket: Ticket) {
        resolve(ticket)
    }

    /// The caller resumes the waiter; the id stays out until the late reply.
    mutating func cancelledWhileInFlight(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        outstanding[ticket.id] = nil
        awaitingLateReply.insert(ticket.id)
    }

    /// Only the allocation still out owes a refusal; a late handler for a
    /// resolved or reissued id does nothing.
    mutating func cancelledBeforeRegistration(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        refuseOnRegistration.insert(ticket)
    }

    /// `true` when the reply was expected; the id is free again.
    mutating func acceptLateReply(_ id: UInt32) -> Bool {
        guard awaitingLateReply.remove(id) != nil else { return false }
        free.append(id)
        return true
    }

    /// Exposed so tests can prove stale cancellations add nothing: an entry
    /// for a registration already over would never be removed.
    var retainedRefusalCount: Int { refuseOnRegistration.count }

    var retainedLateReplyCount: Int { awaitingLateReply.count }

    private mutating func resolve(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        outstanding[ticket.id] = nil
        free.append(ticket.id)
    }
}
