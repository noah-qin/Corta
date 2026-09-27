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

import AppKit
import Testing

@testable import Corta

/// What a pane does on a GPU without `MTLGPUFamily.metal4`: it says so, and
/// starts nothing. Metal 4 is the only renderer (#109), so there is no
/// second one to fall back to, and a shell nobody can see is not started.
///
/// Runs exactly where that is true — the hosted CI runner's paravirtual GPU
/// (issue #107) — and is skipped on Apple silicon, where every pane renders.
/// The rest of what such a pane must survive is AppKit's ordinary churn: a
/// font-size change and a focus change reached a failed pane's missing
/// session and renderer and crashed the app before this was written.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: !MetalRenderTarget.supportsMetal4,
        "runs only on a GPU without Metal 4, where a pane cannot render"))
struct Metal4UnavailablePaneTests {
    @Test func aPaneSaysMetal4IsMissingAndStartsNoShell() throws {
        let pane = ViewController()
        _ = pane.view
        let failure = try #require(pane.failureView, "expected the failure pane")
        #expect(failure.announcement.hasPrefix(L10n.text("failure.title.metal4")))
        #expect(pane.session == nil, "a pane that cannot render must not start a shell")
        #expect(!pane.isOperable)
    }

    @Test func aFailedPaneSurvivesAFontSizeAndAFocusChange() throws {
        let pane = ViewController()
        _ = pane.view
        #expect(pane.failureView != nil)
        pane.setFontSize(pane.fontSize + 2)
        pane.reportFocusIfNeeded()
        pane.applyFocusAppearance()
        #expect(pane.failureView != nil)
    }
}
