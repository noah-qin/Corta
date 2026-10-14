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
import SwiftUI

/// The third-party notices that must travel with the app.
///
/// Sparkle is Corta's one runtime dependency (D23). Its license is MIT, and
/// it also carries the BSD and zlib-style notices of the code it bundles
/// (bsdiff, sais-lite, ed25519, `SUSignatureVerifier`); the MIT and BSD
/// terms both require the notice to accompany the software, which for a
/// downloaded app means inside it. `Sparkle-LICENSE.txt` is Sparkle's
/// `LICENSE` file, verbatim, from the version `Package.resolved` pins —
/// `AcknowledgementsTests` fails when the two drift apart.
struct AcknowledgementsView: View {
    /// The Sparkle release whose license the bundle carries.
    static let sparkleVersion = "2.10.0"

    /// The bundled license text, or `nil` in a build that lost the
    /// resource — shown as such rather than as an empty page.
    static var sparkleLicense: String? {
        Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("acknowledgements.sparkle", Self.sparkleVersion))
                .font(.system(size: 12))
            ScrollView {
                Text(Self.sparkleLicense ?? L10n.text("acknowledgements.missing"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
        .padding(16)
        .frame(width: 680, height: 520)
    }
}

/// Hosts `AcknowledgementsView` in a window of its own, opened from About.
@MainActor
final class AcknowledgementsWindowController: NSWindowController {
    static let shared = AcknowledgementsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.text("acknowledgements.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: AcknowledgementsView())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
