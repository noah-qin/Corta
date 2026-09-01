import Testing

@testable import CortaTerminal

@Suite("Child environment")
struct ChildEnvironmentTests {
    @Test("terminal-describing variables are replaced, not inherited")
    func terminalVariablesAreReplaced() {
        let sanitized = ChildEnvironment.sanitized(inheriting: [
            "TERM": "screen-256color",
            "TERMCAP": "junk",
            "TERM_PROGRAM": "Apple_Terminal",
            "COLUMNS": "999",
            "LINES": "999",
        ])
        #expect(sanitized["TERM"] == "xterm-256color")
        #expect(sanitized["TERM_PROGRAM"] == "Corta")
        #expect(sanitized["TERMCAP"] == nil)
        #expect(sanitized["COLUMNS"] == nil)
        #expect(sanitized["LINES"] == nil)
    }

    @Test("Corta's own variables never reach the child")
    func internalVariablesAreStripped() {
        let sanitized = ChildEnvironment.sanitized(inheriting: ["CORTA_SESSION": "42"])
        #expect(sanitized["CORTA_SESSION"] == nil)
    }

    @Test("everything else is passed through")
    func otherVariablesArePreserved() {
        let sanitized = ChildEnvironment.sanitized(inheriting: [
            "PATH": "/usr/bin",
            "HOME": "/Users/someone",
            "SSH_AUTH_SOCK": "/tmp/socket",
        ])
        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/Users/someone")
        #expect(sanitized["SSH_AUTH_SOCK"] == "/tmp/socket")
    }

    @Test("the process environment is readable")
    func processEnvironmentIsReadable() {
        let environment = ChildEnvironment.processEnvironment()
        #expect(!environment.isEmpty)
        #expect(environment["PATH"] != nil)
    }
}
