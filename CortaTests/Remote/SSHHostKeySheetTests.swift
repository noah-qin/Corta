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

@MainActor
struct SSHHostKeySheetTests {
    private static let fingerprint = "SHA256:n6PdUL7mLyRkBXBQf3JmWJPTQ2GtTzfZqcPmjAML5GY"
    static let hostKeyQuestion = """
        The authenticity of host 'prod' can't be established.
        ED25519 key fingerprint is \(fingerprint).
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    @Test("the sheet shows the entire fingerprint or explains why it is unavailable")
    func hostKeyFingerprint() {
        let asking = { (text: String) in
            SSHHostKeyPrompt(SSHAskpass.Asking(question: .hostKey, host: "prod", prompt: text))
        }
        let sha256 = asking(Self.hostKeyQuestion)
        #expect(sha256.fingerprint == .init(keyType: "ED25519", value: Self.fingerprint))
        #expect(sha256.canContinue)
        #expect(sha256.details == Self.hostKeyQuestion)
        let md5 = "MD5:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"
        #expect(asking("RSA key fingerprint is: \(md5)").fingerprint == .init(keyType: "RSA", value: md5))
        let missing = asking("?")
        #expect(missing.fingerprint == nil)
        #expect(missing.details.isEmpty)
        #expect(missing.advice == L10n.text("askpass.hostKey.missing"))
        #expect(!missing.canContinue)
        #expect(!asking("ED25519 key fingerprint is SHA256:abc…").canContinue)

        let conflictingAddress = asking("""
            Warning: the ED25519 host key for 'prod' differs from the key for the IP address '192.0.2.4'
            Offending key for IP in /tmp/known_hosts:1
            Are you sure you want to continue connecting (yes/no)?
            """)
        #expect(conflictingAddress.fingerprint == nil)
        #expect(conflictingAddress.isAddressConflict)
        #expect(conflictingAddress.canContinue)
    }

    @Test("Return and keypad Enter cancel the host-key sheet")
    func returnCancelsHostKeySheet() throws {
        let prompt = SSHHostKeyPrompt(.init(question: .hostKey, host: "prod", prompt: Self.hostKeyQuestion))
        var responses: [NSApplication.ModalResponse] = []
        let sheet = SSHHostKeySheet.makePanel(prompt) { _, response in responses.append(response) }
        for (keyCode, character) in [(36, "\r"), (76, "\u{3}")] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: UInt16(keyCode)))
            #expect(sheet.performKeyEquivalent(with: event))
        }
        #expect(responses == [.cancel, .cancel])
    }
}
