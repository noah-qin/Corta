import Testing

@testable import CortaTerminal

/// The cancellation orderings the session cannot be driven through from
/// outside — each turns on a window between a continuation resuming and a
/// cancellation handler being uninstalled — held here, where each is a few
/// lines. Three of them are bugs that shipped or nearly did (#129, #128).
@Suite("SFTP request-id ledger")
struct SFTPRequestIDLedgerTests {

    @Test("an id is not handed out twice while it is outstanding")
    func allocationIsUnique() {
        var ledger = SFTPRequestIDLedger()
        let ids = (0..<8).map { _ in ledger.allocate().id }
        #expect(Set(ids).count == ids.count)
    }

    @Test("every allocation is distinct even when the id repeats")
    func generationsNeverRepeat() {
        var ledger = SFTPRequestIDLedger()
        let first = ledger.allocate()
        ledger.resolved(first)
        let second = ledger.allocate()
        #expect(second.id == first.id, "the id is recycled")
        #expect(second.generation != first.generation, "the allocation is not")
    }

    @Test("an ordinary request registers and is sent")
    func registrationAllowsTheSend() {
        var ledger = SFTPRequestIDLedger()
        let ticket = ledger.allocate()
        let maySend = ledger.register(ticket)
        #expect(maySend)
    }

    /// Cancelled between allocation and registration: the registration
    /// finds the refusal, declines to send, and gives the id back.
    @Test("a request cancelled before it registers is refused, once")
    func cancellationBeforeRegistrationRefusesTheSend() {
        var ledger = SFTPRequestIDLedger()
        let ticket = ledger.allocate()
        ledger.cancelledBeforeRegistration(ticket)
        let refused = ledger.register(ticket)
        #expect(!refused, "the send must be refused")
        let givenBack = ledger.allocate()
        #expect(givenBack.id == ticket.id, "and the id given back")
        let nextHolderMaySend = ledger.register(givenBack)
        #expect(nextHolderMaySend, "the next holder of that id sends normally")
    }

    /// #129. A refusal must not be left on an id that has gone back into
    /// circulation, or the next sender is refused in its place.
    @Test("a refusal never reaches the next holder of a recycled id")
    func refusalDoesNotLeakToTheNextHolder() {
        var ledger = SFTPRequestIDLedger()
        let cancelled = ledger.allocate()
        ledger.cancelledBeforeRegistration(cancelled)
        _ = ledger.register(cancelled)
        let reused = ledger.allocate()
        #expect(reused.id == cancelled.id, "the id is back in circulation")
        let maySend = ledger.register(reused)
        #expect(maySend, "and its new holder is allowed to send")
    }

    /// #128. `withTaskCancellationHandler` may run its handler after the
    /// operation completed, so a cancellation arrives for a request whose
    /// reply already landed and whose id is already free. Marking that
    /// stranded a refusal on a free id, and the next sender — the CLOSE
    /// after an aborted download — was refused a send it never asked to
    /// cancel, without anything reaching the wire.
    @Test("a cancellation arriving after the reply leaves nothing behind")
    func cancellationAfterCompletionIsIgnored() {
        var ledger = SFTPRequestIDLedger()
        let read = ledger.allocate()
        let readSent = ledger.register(read)
        #expect(readSent)
        ledger.resolved(read)  // the reply arrived; the id is free

        ledger.cancelledBeforeRegistration(read)  // the handler, late

        let close = ledger.allocate()
        #expect(close.id == read.id, "the CLOSE takes the recycled id")
        let closeSent = ledger.register(close)
        #expect(closeSent, "and must be allowed to send it")
    }

    /// The same lateness, but with the id already reissued to a *different*
    /// sender before the handler runs — two transfers share one session, so
    /// this is the ordinary case rather than a corner. Guarding only on
    /// "is this id outstanding" passes here and refuses the wrong request;
    /// the generation is what does not.
    @Test("a late cancellation does not refuse the sender that now holds the id")
    func lateCancellationDoesNotRefuseTheNewHolder() {
        var ledger = SFTPRequestIDLedger()
        let first = ledger.allocate()
        let firstSent = ledger.register(first)
        #expect(firstSent)
        ledger.resolved(first)

        // Another transfer takes the id and has not registered yet.
        let second = ledger.allocate()
        #expect(second.id == first.id)

        ledger.cancelledBeforeRegistration(first)  // the first sender's handler, late

        let secondMaySend = ledger.register(second)
        #expect(secondMaySend, "the new holder's request must still go out")
    }

    /// The symmetric case: the late handler must not take the id out of
    /// circulation on behalf of an allocation that has already resolved,
    /// because the holder it would strand is someone else's live request.
    @Test("a late in-flight cancellation does not strand the new holder's id")
    func lateInFlightCancellationDoesNotStrandTheNewHolder() {
        var ledger = SFTPRequestIDLedger()
        let first = ledger.allocate()
        let firstSent = ledger.register(first)
        #expect(firstSent)
        ledger.resolved(first)

        let second = ledger.allocate()
        #expect(second.id == first.id)

        ledger.cancelledWhileInFlight(first)  // late, for the previous allocation

        let lateReplyExpected = ledger.acceptLateReply(second.id)
        #expect(!lateReplyExpected, "the id was never cancelled in this allocation")
        ledger.resolved(second)
        let recycled = ledger.allocate()
        #expect(recycled.id == second.id, "and it goes back into circulation normally")
    }

    /// Cancelled while registered: the server still owes a reply, so the
    /// id cannot go back into circulation until that reply lands, or the
    /// late reply would be indistinguishable from the next request's.
    @Test("an id cancelled in flight waits for the server's late reply")
    func cancellationInFlightHoldsTheIDUntilTheReply() {
        var ledger = SFTPRequestIDLedger()
        let ticket = ledger.allocate()
        let sent = ledger.register(ticket)
        #expect(sent)
        ledger.cancelledWhileInFlight(ticket)

        let other = ledger.allocate()
        #expect(other.id != ticket.id, "the id must not be reused yet")

        let accepted = ledger.acceptLateReply(ticket.id)
        #expect(accepted, "the late reply is expected and swallowed")
        let acceptedTwice = ledger.acceptLateReply(ticket.id)
        #expect(!acceptedTwice, "and only once")
    }

    @Test("a reply for an id nobody is waiting on is not mistaken for a late one")
    func anUnknownReplyIsNotAcceptedAsLate() {
        var ledger = SFTPRequestIDLedger()
        let accepted = ledger.acceptLateReply(4242)
        #expect(!accepted)
    }

    /// The two cancellation kinds in sequence: the ledger must not confuse
    /// an id held for a late reply with one refused at registration.
    @Test("the two cancellation kinds do not interfere")
    func theTwoCancellationKindsAreIndependent() {
        var ledger = SFTPRequestIDLedger()
        let inFlight = ledger.allocate()
        let inFlightSent = ledger.register(inFlight)
        #expect(inFlightSent)
        ledger.cancelledWhileInFlight(inFlight)

        let beforeRegistration = ledger.allocate()
        ledger.cancelledBeforeRegistration(beforeRegistration)
        let refused = ledger.register(beforeRegistration)
        #expect(!refused)

        let lateAccepted = ledger.acceptLateReply(inFlight.id)
        #expect(lateAccepted)
        let neverSent = ledger.acceptLateReply(beforeRegistration.id)
        #expect(!neverSent, "that one never went out")
    }
}

/// What the guards in `cancelledBeforeRegistration` and
/// `cancelledWhileInFlight` are actually for.
///
/// The `Ticket` key is what makes a stale cancellation *harmless* — the
/// allocation it names is over, so nobody looks the refusal up again. The
/// guards are what stop it being *retained*: without them every late
/// handler leaves an entry nothing will ever remove, and on a long-lived
/// session that grows without bound. Behaviour tests cannot see that,
/// which is why these count instead.
@Suite("SFTP request-id ledger, retention")
struct SFTPRequestIDLedgerRetentionTests {

    @Test("a cancellation for an allocation that already resolved is not retained")
    func staleRefusalIsNotRetained() {
        var ledger = SFTPRequestIDLedger()
        let ticket = ledger.allocate()
        let sent = ledger.register(ticket)
        #expect(sent)
        ledger.resolved(ticket)

        for _ in 0..<100 { ledger.cancelledBeforeRegistration(ticket) }

        #expect(ledger.retainedRefusalCount == 0, "a finished allocation owes no refusal")
    }

    @Test("a cancellation naming a superseded allocation is not retained")
    func supersededRefusalIsNotRetained() {
        var ledger = SFTPRequestIDLedger()
        let first = ledger.allocate()
        let sent = ledger.register(first)
        #expect(sent)
        ledger.resolved(first)
        let second = ledger.allocate()
        #expect(second.id == first.id)

        for _ in 0..<100 { ledger.cancelledBeforeRegistration(first) }

        #expect(ledger.retainedRefusalCount == 0, "the id belongs to another allocation now")
    }

    @Test("a late in-flight cancellation for a finished allocation holds no id back")
    func staleInFlightCancellationHoldsNothing() {
        var ledger = SFTPRequestIDLedger()
        let ticket = ledger.allocate()
        let sent = ledger.register(ticket)
        #expect(sent)
        ledger.resolved(ticket)

        for _ in 0..<100 { ledger.cancelledWhileInFlight(ticket) }

        #expect(ledger.retainedLateReplyCount == 0, "no reply is owed for a finished request")
    }

    @Test("a live cancellation is still retained until its registration or reply")
    func liveCancellationsAreRetained() {
        var ledger = SFTPRequestIDLedger()
        let refused = ledger.allocate()
        ledger.cancelledBeforeRegistration(refused)
        #expect(ledger.retainedRefusalCount == 1)
        _ = ledger.register(refused)
        #expect(ledger.retainedRefusalCount == 0, "the registration clears it")

        let inFlight = ledger.allocate()
        let sent = ledger.register(inFlight)
        #expect(sent)
        ledger.cancelledWhileInFlight(inFlight)
        #expect(ledger.retainedLateReplyCount == 1)
        let accepted = ledger.acceptLateReply(inFlight.id)
        #expect(accepted)
        #expect(ledger.retainedLateReplyCount == 0, "the late reply clears it")
    }
}
