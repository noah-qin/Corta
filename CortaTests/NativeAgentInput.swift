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
import CortaTerminal
import Testing
@testable import Corta

/// A real user Return is encoded from the negotiated keyboard protocol.
/// Keep paste/text delivery separate so a TUI cannot treat Return as pasted text.
@MainActor
func submitNativeAgentPrompt(_ text: String, in session: SpaceSession) async throws {
    let pane = try #require(session.pane)
    let terminal = try #require(pane.session)
    terminal.write(Array(text.utf8))
    try await Task.sleep(for: .milliseconds(200))
    let key = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    pane.terminalView.keyDown(with: key)
}
