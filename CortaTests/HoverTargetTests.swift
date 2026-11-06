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

/// A click opens what the tooltip said, or nothing.
struct HoverTargetTests {
    @Test("the shown target opens; anything else does not")
    func shownTarget() {
        let shown = PanePointer.HoverState.shown(.url("https://a.example/"))
        #expect(PanePointer.clickOpens(.url("https://a.example/"), shown: shown))
        #expect(!PanePointer.clickOpens(.url("https://b.example/"), shown: shown))
        #expect(!PanePointer.clickOpens(.reference("/a:1"), shown: shown))
    }

    @Test("a `path:line` compares by the text its tooltip gave")
    func references() {
        let shown = PanePointer.HoverState.shown(.reference("/a/file.swift:3"))
        #expect(PanePointer.clickOpens(.reference("/a/file.swift:3"), shown: shown))
        #expect(!PanePointer.clickOpens(.reference("/b/file.swift:3"), shown: shown))
    }

    @Test("a hover that found nothing shows nothing, so a link appearing since does not open")
    func nothingShown() {
        #expect(!PanePointer.clickOpens(.url("https://a.example/"), shown: .shown(nil)))
        // A local path whose check has not answered had no chance to show.
        #expect(PanePointer.clickOpens(.reference("/a:1"), pending: true, shown: .shown(nil)))
        #expect(!PanePointer.clickOpens(.reference("/b:1"), pending: true, shown: .shown(.reference("/a:1"))))
    }

    @Test("no hover at all has shown nothing to differ from")
    func noHover() {
        #expect(PanePointer.clickOpens(.url("https://a.example/"), shown: .none))
    }
}
