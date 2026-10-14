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

import Foundation
import Testing
@testable import Corta

struct SSHConnectionTests {
    private func target(
        _ host: String, user: String = "", port: String = "", identityFile: String = ""
    ) -> Result<SSHTarget, SSHTarget.Problem> {
        SSHTarget.parse(host: host, user: user, port: port, identityFile: identityFile)
    }

    @Test func aliasesPreserveSSHConfigUserPortAndKey() throws {
        let preset = SSHDestination.preset(for: try target("build-box").get())
        #expect(preset.shell == "/usr/bin/ssh")
        #expect(preset.arguments == ["--", "build-box"])
        #expect(preset.connectTarget?.displayName == "build-box")
    }

    @Test func userAndPortAreTheirOwnArguments() throws {
        let value = try target(" box.example ", user: "deploy", port: "2222").get()
        #expect(value.sshArguments == ["-l", "deploy", "-p", "2222", "--", "box.example"])
        #expect(value.displayName == "deploy@box.example:2222")
    }

    @Test func userAtHostInTheHostFieldStillWorks() throws {
        let value = try target("deploy@box").get()
        #expect(value.user == "deploy")
        #expect(value.host == "box")
        #expect(value.sshArguments == ["-l", "deploy", "--", "box"])
        #expect(target("deploy@box", user: "other") == .failure(.userTwice))
    }

    @Test func anIPv6LiteralIsBracketedOnlyWhereAPortFollows() throws {
        #expect(try target("2001:db8::1", user: "u", port: "2222").get().displayName == "u@[2001:db8::1]:2222")
        #expect(try target("[2001:db8::1]", port: "22").get().displayName == "[2001:db8::1]:22")
        #expect(try target("[2001:db8::1]").get().host == "2001:db8::1", "ssh is given the address")
        #expect(try target("u@2001:db8::1").get().displayName == "u@2001:db8::1")
    }

    @Test func aChosenKeyIsTheOnlyOneOffered() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("corta-key-\(UUID().uuidString)")
        try Data("key".utf8).write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }
        let value = try target("box", identityFile: key.path).get()
        #expect(value.sshArguments == ["-i", key.path, "-oIdentitiesOnly=yes", "--", "box"])
        #expect(value.displayName == "box", "the key says how to sign in, not where to")
    }

    @Test func aKeyMustBeAReadableFileAtAnAbsolutePathSSHWillNotExpand() throws {
        let missing = "/nonexistent/corta-\(UUID().uuidString)"
        #expect(target("box", identityFile: missing) == .failure(.identityFileMissing))
        #expect(target("box", identityFile: "/tmp") == .failure(.identityFileMissing), "a directory")
        #expect((try? SSHTarget.parse(host: "box", identityFile: missing, checkingFiles: false).get()) != nil)
        for path in ["id_ed25519", "~/.ssh/id_ed25519", "/keys/%h", "/keys/${HOME}", "/keys/a\nb", " /keys/k"] {
            #expect(target("box", identityFile: path) == .failure(.identityFile), "\(path)")
        }
    }

    @Test(arguments: ["", "-oProxyCommand=bad", "a;touch", "a\nb", "user@", "a@b@c", "a b", "a$(echo)", "host%h", "box:22", "[2001:db8::1]:22", "[::1", "[box]", "box]"])
    func rejectsInvalidHosts(_ host: String) {
        #expect(target(host) == .failure(.host))
    }

    @Test(arguments: ["-oEvil", "a b", "a%u", "${USER}", "a;b", "\u{4E2D}"])
    func rejectsInvalidUsers(_ user: String) {
        #expect(target("box", user: user) == .failure(.user))
    }

    @Test func anEmptyUserBeforeTheAtIsRefused() {
        #expect(target("@host") == .failure(.user))
    }

    @Test(arguments: ["0", "-1", "65536", "22a", "port"]) func rejectsInvalidPorts(_ port: String) {
        #expect(target("host", port: port) == .failure(.port))
    }

    /// The window registry, remote editing and its saved copies name a
    /// connection by `key`; reading it back must give the same connection,
    /// key included, with nothing remembered on the side.
    @Test func aKeyReadsBackAsTheSameTarget() throws {
        let targets: [SSHTarget] = [
            SSHTarget(host: "box"),
            SSHTarget(host: "box", user: "deploy"),
            SSHTarget(host: "box", user: "deploy", port: 2222),
            SSHTarget(host: "2001:db8::1", user: "u", port: 22),
            SSHTarget(host: "2001:db8::1"),
            SSHTarget(host: "box", port: 2200, identityFile: "/Users/me/.ssh/work key "),
        ]
        for value in targets {
            #expect(SSHTarget(key: value.key) == value, "\(value.key)")
        }
        #expect(SSHTarget(host: "box", identityFile: "/k").key == "box -i /k")
        #expect(SSHTarget(host: "box", identityFile: "/k").displayName == "box")
        #expect(SSHTarget.displayName(forKey: "u@box:22 -i /k") == "u@box:22")
        for bad in ["", "@box", "box:", "[box]:22", "-oEvil", "box -i relative"] {
            #expect(SSHTarget(key: bad) == nil, "\(bad)")
        }
    }

    /// A pane's report is child output: read as a bare name, it can carry
    /// neither a port nor the file ssh signs in with.
    @Test func aReportedNameTakesNoPortAndNoKey() {
        #expect(SSHTarget.named("deploy@box") == SSHTarget(host: "box", user: "deploy"))
        #expect(SSHTarget.named("box:22") == nil)
        #expect(SSHTarget.named("box -i /etc/ssh/key") == nil)
    }
}
