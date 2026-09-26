/// The request-id lifecycle, as a value.
///
/// **Why this is not just four fields on the session.** The orderings it
/// has to get right cost two bugs to fix and a third to notice, and in the
/// session none of them could be tested: the window each turns on is
/// between a continuation resuming and a cancellation handler being
/// uninstalled, which nothing outside the session can drive. As a value
/// every ordering is three lines in a test.
///
/// An id may only be handed out again once nothing can still arrive for
/// it. Three things can:
///
/// - **A reply the server still owes.** A request cancelled while
///   registered has had its waiter resumed already, but the server does
///   not know that; its reply is still coming. Recycling the id first
///   would make that reply indistinguishable from the next request's, so
///   the id waits in `awaitingLateReply` until it lands.
/// - **A registration that has not happened yet.** A request cancelled
///   between allocation and registration has no waiter to resume, so the
///   refusal is left for the registration to find. Recycling the id at
///   cancellation time instead handed it to the next sender, whose
///   registration found a refusal meant for someone else and failed
///   `.cancelled` *without sending anything* — the CLOSE after an aborted
///   download went missing exactly this way.
/// - **Nothing at all.** An id that has already resolved owes no refusal.
///   `withTaskCancellationHandler` may run its handler after the operation
///   completes, so a cancellation can arrive for a request whose reply
///   already landed and whose id is already back in `free`. Marking *that*
///   strands a refusal on a free id, and the next sender — in practice the
///   CLOSE, again — is refused a send it never asked to cancel.
///
/// **An id is not a request.** The same id is handed out over and over, so
/// a cancellation that names only an id lands on whoever holds it *now*,
/// which with two transfers sharing one session is routinely someone else.
/// Guarding on "is this id outstanding" narrows that to "outstanding for a
/// different sender" and no further. Every allocation therefore carries a
/// generation, and a cancellation names the allocation it belongs to:
/// a stale handler compares unequal and does nothing, whether the id has
/// been reissued or not.
struct SFTPRequestIDLedger {
    /// One allocation of one id. The pair is what "this request" means;
    /// the id alone is only what goes on the wire.
    struct Ticket: Hashable, Sendable {
        let id: UInt32
        let generation: UInt64
    }

    /// The counter behind a fresh id. 32 bits, and the window bounds how
    /// many are live, so the wrap is safe: an id can only collide with a
    /// live one after four billion allocations.
    private var nextID: UInt32 = 0

    /// Recycled ids, LIFO. Only ids nothing can still arrive for.
    private var free: [UInt32] = []

    /// Never reused, so two allocations of one id are never equal.
    private var nextGeneration: UInt64 = 0

    /// The live allocation of each id that is out — allocated and not yet
    /// answered, failed, refused or cancelled.
    private var outstanding: [UInt32: UInt64] = [:]

    /// Cancelled while the server still owed a reply.
    private var awaitingLateReply: Set<UInt32> = []

    /// Cancelled after allocation and before registration; the
    /// registration finds this and declines to send.
    private var refuseOnRegistration: Set<Ticket> = []

    /// Takes the next id, recycling from the freed pool first, and stamps
    /// it with a generation nothing else will ever carry.
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

    /// Whether the request may be sent. `false` means *this allocation*
    /// was cancelled between allocation and here, and the id is recycled.
    mutating func register(_ ticket: Ticket) -> Bool {
        guard refuseOnRegistration.remove(ticket) != nil else { return true }
        resolve(ticket)
        return false
    }

    /// A reply arrived for a registered request, or its write failed: the
    /// id is free again.
    mutating func resolved(_ ticket: Ticket) {
        resolve(ticket)
    }

    /// Cancelled while registered. The waiter is resumed by the caller;
    /// the id stays out of circulation until the server's late reply
    /// lands.
    mutating func cancelledWhileInFlight(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        outstanding[ticket.id] = nil
        awaitingLateReply.insert(ticket.id)
    }

    /// Cancelled with no waiter registered.
    ///
    /// Only the allocation that is still out owes a refusal. A handler
    /// running late for an allocation that has resolved — or for one whose
    /// id has since been reissued to somebody else — compares unequal and
    /// does nothing.
    mutating func cancelledBeforeRegistration(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        refuseOnRegistration.insert(ticket)
    }

    /// A reply for an id whose request was cancelled in flight: `true`
    /// when it was expected, and the id is now free.
    mutating func acceptLateReply(_ id: UInt32) -> Bool {
        guard awaitingLateReply.remove(id) != nil else { return false }
        free.append(id)
        return true
    }

    /// Refusals waiting for a registration that will come. A stale
    /// cancellation must not add to this: the registration it would be
    /// waiting for is already over, so the entry would never be removed.
    /// The `Ticket` key is what keeps such an entry *harmless*; the guards
    /// are what keep the set from growing without bound.
    var retainedRefusalCount: Int { refuseOnRegistration.count }

    /// Ids held back until the server's late reply lands, for the same
    /// reason.
    var retainedLateReplyCount: Int { awaitingLateReply.count }

    private mutating func resolve(_ ticket: Ticket) {
        guard outstanding[ticket.id] == ticket.generation else { return }
        outstanding[ticket.id] = nil
        free.append(ticket.id)
    }
}
