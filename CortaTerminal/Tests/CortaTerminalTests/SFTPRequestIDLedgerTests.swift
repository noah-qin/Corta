import Testing

@testable import CortaTerminal

/// The three cancellation orderings the session cannot be driven through
/// from outside — each turns on a window between a continuation resuming
/// and a cancellation handler being uninstalled — held here, where each is
/// three lines. Two of them are bugs that shipped (#129, #128).
@Suite("SFTP request-id ledger")
struct SFTPRequestIDLedgerTests {

    @Test("an id is not handed out twice while it is outstanding")
    func allocationIsUnique() {
        var ledger = SFTPRequestIDLedger()
        let ids = (0..<8).map { _ in ledger.allocate() }
        #expect(Set(ids).count == ids.count)
    }

    @Test("a resolved id is handed out again")
    func resolvedIDsAreRecycled() {
        var ledger = SFTPRequestIDLedger()
        let first = ledger.allocate()
        ledger.resolved(first)
        let recycled = ledger.allocate()
        #expect(recycled == first)
    }

    @Test("an ordinary request registers and is sent")
    func registrationAllowsTheSend() {
        var ledger = SFTPRequestIDLedger()
        let id = ledger.allocate()
        let maySend = ledger.register(id)
        #expect(maySend)
    }

    /// Cancelled between allocation and registration: the registration
    /// finds the refusal, declines to send, and gives the id back.
    @Test("a request cancelled before it registers is refused, once")
    func cancellationBeforeRegistrationRefusesTheSend() {
        var ledger = SFTPRequestIDLedger()
        let id = ledger.allocate()
        ledger.cancelledBeforeRegistration(id)
        let refused = ledger.register(id)
        #expect(!refused, "the send must be refused")
        let givenBack = ledger.allocate()
        #expect(givenBack == id, "and the id given back")
        let nextHolderMaySend = ledger.register(givenBack)
        #expect(nextHolderMaySend, "the next holder of that id sends normally")
    }

    /// #129. The refusal must not be left on an id that has gone back into
    /// circulation, or the next sender is refused in its place.
    @Test("a refusal never reaches the next holder of a recycled id")
    func refusalDoesNotLeakToTheNextHolder() {
        var ledger = SFTPRequestIDLedger()
        let cancelled = ledger.allocate()
        ledger.cancelledBeforeRegistration(cancelled)
        _ = ledger.register(cancelled)
        let reused = ledger.allocate()
        #expect(reused == cancelled, "the id is back in circulation")
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
        #expect(close == read, "the CLOSE takes the recycled id")
        let closeSent = ledger.register(close)
        #expect(closeSent, "and must be allowed to send it")
    }

    /// Cancelled while registered: the server still owes a reply, so the
    /// id cannot go back into circulation until that reply lands, or the
    /// late reply would be indistinguishable from the next request's.
    @Test("an id cancelled in flight waits for the server's late reply")
    func cancellationInFlightHoldsTheIDUntilTheReply() {
        var ledger = SFTPRequestIDLedger()
        let id = ledger.allocate()
        let sent = ledger.register(id)
        #expect(sent)
        ledger.cancelledWhileInFlight(id)

        let other = ledger.allocate()
        #expect(other != id, "the id must not be reused yet")

        let accepted = ledger.acceptLateReply(id)
        #expect(accepted, "the late reply is expected and swallowed")
        let acceptedTwice = ledger.acceptLateReply(id)
        #expect(!acceptedTwice, "and only once")
    }

    @Test("a reply for an id nobody is waiting on is not mistaken for a late one")
    func anUnknownReplyIsNotAcceptedAsLate() {
        var ledger = SFTPRequestIDLedger()
        let accepted = ledger.acceptLateReply(4242)
        #expect(!accepted)
    }

    /// The two cancellation paths in sequence: the ledger must not confuse
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

        let lateAccepted = ledger.acceptLateReply(inFlight)
        #expect(lateAccepted)
        let neverSent = ledger.acceptLateReply(beforeRegistration)
        #expect(!neverSent, "that one never went out")
    }
}
