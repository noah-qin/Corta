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
        for path in ["id_ed25519", "~/.ssh/id_ed25519", "/keys/%h", "/keys/${HOME}", "/keys/a\nb"] {
            #expect(target("box", identityFile: path) == .failure(.identityFile), "\(path)")
        }
    }

    @Test(arguments: ["", "-oProxyCommand=bad", "a;touch", "a\nb", "user@", "a@b@c", "a b", "a$(echo)", "host%h", "box:22", "[2001:db8::1]:22", "[::1", "[box]"])
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

    @Test func aTargetEnteredThisRunResolvesByItsName() throws {
        let value = try target("resolve-\(UUID().uuidString)", user: "deploy", port: "2200").get()
        #expect(SSHTarget.resolve(value.displayName) == nil, "never entered: not a plain host either")
        SSHTarget.remember(value)
        #expect(SSHTarget.resolve(value.displayName) == value)
        #expect(SSHTarget.resolve("plain-box") == SSHTarget(host: "plain-box"))
    }
}
