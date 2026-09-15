import Foundation
import Testing

@testable import CortaTerminal

/// B14 — the subprocess channel's pure policy: argv shape and exit
/// classification. Nothing here spawns a process; the channel's real
/// subprocess is exercised only in the app, never in tests.
@Suite("SFTP channel")
struct SFTPChannelTests {
    @Test("the ssh invocation is `ssh -s -- <host> sftp`")
    func invocationArguments() {
        // `--` before the host: a hostile or mistyped host must never be
        // parsed as an ssh option.
        #expect(
            SFTPSubprocessChannel.arguments(host: "example.com")
                == ["-s", "--", "example.com", "sftp"])
        #expect(
            SFTPSubprocessChannel.arguments(host: "-oProxyCommand=evil")
                == ["-s", "--", "-oProxyCommand=evil", "sftp"])
    }

    @Test("exit 255 with a permission refusal is an authentication failure")
    func authenticationFailure() {
        let error = SFTPTransportError.classify(
            exit: .exited(code: 255),
            diagnostics: "noah@example.com: Permission denied (publickey,password).\r\n")
        guard case .authenticationFailed(let diagnostics) = error else {
            Issue.record("expected .authenticationFailed, got \(error)")
            return
        }
        #expect(diagnostics.contains("Permission denied"))
    }

    @Test("exit 255 with no methods left is an authentication failure")
    func authenticationExhausted() {
        let error = SFTPTransportError.classify(
            exit: .exited(code: 255),
            diagnostics: "no supported authentication methods available")
        #expect(
            error == .authenticationFailed(
                diagnostics: "no supported authentication methods available"))
    }

    @Test("exit 255 with resolution or routing trouble is host-unreachable")
    func hostUnreachable() {
        let cases = [
            "ssh: Could not resolve hostname nosuch: nodename nor servname not known",
            "ssh: connect to host 10.0.0.1 port 22: Connection refused",
            "ssh: connect to host 10.0.0.1 port 22: Operation timed out",
            "ssh: connect to host 10.0.0.1 port 22: No route to host",
        ]
        for diagnostics in cases {
            let error = SFTPTransportError.classify(exit: .exited(code: 255), diagnostics: diagnostics)
            guard case .hostUnreachable = error else {
                Issue.record("expected .hostUnreachable for \(diagnostics), got \(error)")
                continue
            }
        }
    }

    /// The channel has no terminal, so ssh can never ask "are you sure
    /// you want to continue connecting?" — the failure is its own kind,
    /// with its own remedy (connect once in the terminal), and must not
    /// fall through to the unclassified bucket or be mistaken for a bad
    /// password.
    @Test("exit 255 on an unverifiable host key is its own failure")
    func hostKeyUnverified() {
        let cases = [
            "Host key verification failed.\r\n",
            "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.",
        ]
        for diagnostics in cases {
            let error = SFTPTransportError.classify(exit: .exited(code: 255), diagnostics: diagnostics)
            guard case .hostKeyUnverified = error else {
                Issue.record("expected .hostKeyUnverified for \(diagnostics), got \(error)")
                continue
            }
        }
    }

    @Test("exit 255 without a known signature stays unclassified")
    func unclassifiedFailure() {
        let error = SFTPTransportError.classify(
            exit: .exited(code: 255), diagnostics: "subsystem request failed on channel 0")
        guard case .subprocessFailed(let code, _) = error else {
            Issue.record("expected .subprocessFailed, got \(error)")
            return
        }
        #expect(code == 255)
    }

    @Test("any non-255 exit or a signal is a lost connection")
    func otherExits() {
        #expect(
            SFTPTransportError.classify(exit: .exited(code: 1), diagnostics: "")
                == .connectionLost)
        #expect(
            SFTPTransportError.classify(exit: .exited(code: 0), diagnostics: "")
                == .connectionLost)
        #expect(
            SFTPTransportError.classify(exit: .signalled(signal: 9), diagnostics: "")
                == .connectionLost)
    }
}
