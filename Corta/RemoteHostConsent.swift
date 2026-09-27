import Foundation

/// Which hosts the user has explicitly agreed to let Corta connect
/// to over SFTP in this run of the app.
///
/// The host a remote pane names comes from the remote shell's own `OSC 7`
/// report (`RemoteContext`), and that is child output: anything the far
/// end prints — a `cat` of a hostile file included — can name whatever
/// host it likes. `SECURITY.md` §7 (remote OSC 7 reports) records the
/// rule: the name is
/// displayed, never used as a host to connect to "without the user's own
/// command doing the connecting". So a reported host is only ever a
/// *suggestion*: the first SFTP connection to it — from the browser or
/// from a ⌘-clicked file reference — is a question the user answers with
/// the name in front of them, editable, and the answer is remembered for
/// the rest of the run. A host typed into the browser by hand is consent
/// by construction.
///
/// Per run and in memory on purpose: persisting consent would turn one
/// approval into a standing permission for a name the next session's
/// output could reuse.
@MainActor
enum RemoteHostConsent {
    private(set) static var confirmedHosts: Set<String> = []

    static func isConfirmed(_ host: String) -> Bool {
        confirmedHosts.contains(host)
    }

    /// Records that the user has chosen to connect to `host` — after
    /// seeing it, not after the far end named it.
    static func confirm(_ host: String) {
        confirmedHosts.insert(host)
    }

    /// Test hook: consent is process-global, and a test that confirmed a
    /// host must not decide the next test's question.
    static func resetForTesting() {
        confirmedHosts.removeAll()
    }
}
