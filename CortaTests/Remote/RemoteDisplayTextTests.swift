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

import CortaTerminal
import Testing

@testable import Corta

/// Each place the app shows a reported host or path goes through
/// `RemoteContext.displayText`, including for a record made before the intake
/// refused such names.
@Suite("Remote display text")
struct RemoteDisplayTextTests {
    @Test("a badge shows no control or format character, whatever the host holds")
    func badgesAreSanitised() {
        for host in ["evil\u{1B}[31m", "evil\u{202E}txt", "evil\u{9B}x"] {
            let badge = PaneRemoteState.badge(host)
            #expect(badge.contains("evil\u{FFFD}"), "\(badge)")
            #expect(!badge.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E || $0.value == 0x9B })
        }
        let state = PaneRemoteState.remote(host: "a\u{202E}b", directory: "/x\u{1B}y", provenance: .osc7)
        #expect(state.titleComponent?.contains("a\u{FFFD}b") == true)
        #expect(state.titleComponent?.contains("x\u{FFFD}y") == true)
    }

    @Test("a path bar's crumb shows the replacement, and still goes to the real path")
    func crumbsShowTheReplacementAndKeepThePath() {
        let crumbs = SFTPPathBar.breadcrumbs(for: "/srv/a\u{202E}b")
        #expect(crumbs.last?.title == "a\u{FFFD}b")
        #expect(crumbs.last?.path == "/srv/a\u{202E}b")
    }
}
