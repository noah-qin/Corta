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
            "COLORTERM": "inherited-and-wrong",
            "LINES": "999",
        ])
        #expect(sanitized["TERM"] == "xterm-256color")
        #expect(sanitized["TERM_PROGRAM"] == "Corta")
        #expect(sanitized["COLORTERM"] == "truecolor")
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
            // An ssh preset that cannot reach the agent is a preset
            // that asks for a password every time; both halves of the agent
            // handshake must survive sanitisation.
            "SSH_AUTH_SOCK": "/tmp/socket",
            "SSH_AGENT_PID": "4242",
        ])
        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/Users/someone")
        #expect(sanitized["SSH_AUTH_SOCK"] == "/tmp/socket")
        #expect(sanitized["SSH_AGENT_PID"] == "4242")
    }

    @Test("the process environment is readable")
    func processEnvironmentIsReadable() {
        let environment = ChildEnvironment.processEnvironment()
        #expect(!environment.isEmpty)
        #expect(environment["PATH"] != nil)
    }
}
