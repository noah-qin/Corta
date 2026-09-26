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
/// - **Nothing at all.** An id that has already resolved owes no refusal,
///   and this is the case that was missing. `withTaskCancellationHandler`
///   may run its handler after the operation completes, so a cancellation
///   can arrive for a request whose reply already landed and whose id is
///   already back in `free`. Marking *that* strands a refusal on a free
///   id, and the next sender — in practice the CLOSE, again — is refused a
///   send it never asked to cancel. `outstanding` is what tells the two
///   apart.
struct SFTPRequestIDLedger {
    /// The counter behind a fresh id. 32 bits, and the window bounds how
    /// many are live, so the wrap is safe: an id can only collide with a
    /// live one after four billion allocations.
    private var nextID: UInt32 = 0

    /// Recycled ids, LIFO. Only ids nothing can still arrive for.
    private var free: [UInt32] = []

    /// Allocated and not yet resolved — answered, failed, refused, or
    /// cancelled. The set `cancelledBeforeRegistration` consults.
    private var outstanding: Set<UInt32> = []

    /// Cancelled while the server still owed a reply.
    private var awaitingLateReply: Set<UInt32> = []

    /// Cancelled after allocation and before registration; the
    /// registration finds this and declines to send.
    private var refuseOnRegistration: Set<UInt32> = []

    /// Takes the next id, recycling from the freed pool first.
    mutating func allocate() -> UInt32 {
        let id: UInt32
        if let recycled = free.popLast() {
            id = recycled
        } else {
            id = nextID
            nextID &+= 1
        }
        outstanding.insert(id)
        return id
    }

    /// Whether the request may be sent. `false` means it was cancelled
    /// between allocation and here, and the id has been recycled.
    mutating func register(_ id: UInt32) -> Bool {
        guard refuseOnRegistration.remove(id) != nil else { return true }
        resolve(id)
        return false
    }

    /// A reply arrived for a registered request, or its write failed: the
    /// id is free again.
    mutating func resolved(_ id: UInt32) {
        resolve(id)
    }

    /// Cancelled while registered. The waiter is resumed by the caller;
    /// the id stays out of circulation until the server's late reply
    /// lands.
    mutating func cancelledWhileInFlight(_ id: UInt32) {
        outstanding.remove(id)
        awaitingLateReply.insert(id)
    }

    /// Cancelled with no waiter registered.
    ///
    /// Only an id still outstanding owes a refusal. One that has already
    /// resolved is ignored — see the type's doc comment; this guard is the
    /// whole of that third case.
    mutating func cancelledBeforeRegistration(_ id: UInt32) {
        guard outstanding.contains(id) else { return }
        refuseOnRegistration.insert(id)
    }

    /// A reply for an id whose request was cancelled in flight: `true`
    /// when it was expected, and the id is now free.
    mutating func acceptLateReply(_ id: UInt32) -> Bool {
        guard awaitingLateReply.remove(id) != nil else { return false }
        free.append(id)
        return true
    }

    private mutating func resolve(_ id: UInt32) {
        outstanding.remove(id)
        free.append(id)
    }
}
