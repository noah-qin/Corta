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
@testable import Corta

struct SSHConnectionTests {
    @Test func aliasesPreserveSSHConfigPort() throws {
        let preset = try #require(SSHDestination.preset(host: "build-box"))
        #expect(preset.shell == "/usr/bin/ssh")
        #expect(preset.arguments == ["--", "build-box"])
    }
    @Test func explicitPortAndIPv6() throws {
        let preset = try #require(SSHDestination.preset(host: " user@[2001:db8::1] ", port: 2222))
        #expect(preset.arguments == ["-p", "2222", "--", "user@[2001:db8::1]"])
    }
    @Test(arguments: ["", "-oProxyCommand=bad", "a;touch", "a\nb", "user@", "@host", "a@b@c", "a b", "a$(echo)"])
    func rejectsInvalidDestinations(_ host: String) {
        #expect(SSHDestination.preset(host: host) == nil)
    }
    @Test(arguments: [0, -1, 65536]) func rejectsInvalidPorts(_ port: Int) {
        #expect(SSHDestination.preset(host: "host", port: port) == nil)
    }
}
