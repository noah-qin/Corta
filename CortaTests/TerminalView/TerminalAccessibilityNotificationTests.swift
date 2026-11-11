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

/// Records what `TerminalView` would post. The test host runs inside Corta
/// Dev and cannot attach an accessibility client to itself, so what a real
/// client receives — the issue's VoiceOver-off + Accessibility Inspector
/// check — stays a human one; these tests pin the notification the client
/// would receive and the laziness that makes posting it unconditionally safe.
@MainActor
private final class AccessibilityNotificationRecorder {
    private(set) var notifications: [NSAccessibility.Notification] = []

    func install(on view: TerminalView) {
        view.accessibilityNotificationPoster = { [weak self] _, notification in
            self?.notifications.append(notification)
        }
    }
}

/// What `TerminalView` announces when the grid or the selection changes, and
/// what it deliberately does not do: build the accessibility snapshot.
///
/// Posting is no longer gated on VoiceOver (`D32`): AppKit cannot report an
/// arbitrary AX client, and the notifications carry no string, so every
/// client hears the change and reads the value only if it asks.
@MainActor
struct TerminalAccessibilityNotificationTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    private func snapshot() -> TerminalAccessibilitySnapshot {
        var terminal = Terminal(rows: 4, columns: 20, scrollbackLimit: 100)
        terminal.feed(Array("hello\nthere".utf8))
        return TerminalAccessibilitySnapshot(grid: terminal.grid, selection: nil)
    }

    // MARK: - The notification itself

    @Test func aGridChangePostsValueChanged() {
        let view = makeView()
        let recorder = AccessibilityNotificationRecorder()
        recorder.install(on: view)
        view.noteAccessibilityValueChanged()
        #expect(recorder.notifications == [.valueChanged])
    }

    @Test func aSelectionChangePostsSelectedTextChanged() {
        let view = makeView()
        let recorder = AccessibilityNotificationRecorder()
        recorder.install(on: view)
        view.noteAccessibilitySelectionChanged()
        #expect(recorder.notifications == [.selectedTextChanged])
    }

    /// A program streaming output calls this once per output batch; a client
    /// must hear about it at most once per interval, and the burst's final
    /// state must still arrive after the interval, or a client that only
    /// listened once would show stale text forever.
    @Test func aBurstIsRateLimitedToOnePostNowAndOneTrailing() async {
        let view = makeView()
        let recorder = AccessibilityNotificationRecorder()
        recorder.install(on: view)
        for _ in 0..<1_000 { view.noteAccessibilityValueChanged() }
        #expect(recorder.notifications == [.valueChanged], "the first post is immediate")
        await waitUntil("the trailing valueChanged post") { recorder.notifications.count == 2 }
        #expect(recorder.notifications == [.valueChanged, .valueChanged])
    }

    /// A selection moves at human speed, and a client needs its final position
    /// even inside a value post's interval — so this one is not rate-limited.
    @Test func everySelectionChangePosts() {
        let view = makeView()
        let recorder = AccessibilityNotificationRecorder()
        recorder.install(on: view)
        view.noteAccessibilitySelectionChanged()
        view.noteAccessibilitySelectionChanged()
        view.noteAccessibilitySelectionChanged()
        #expect(recorder.notifications.count == 3)
    }

    // MARK: - Laziness: posting never builds the snapshot

    /// The production path, with no client attached and no test seam: a flood
    /// posts (rate-limited) but never asks the pane to flatten the grid into
    /// strings, which is what keeps this off the render path (`PERFORMANCE.md`
    /// §2). The trailing post after the interval must be lazy too.
    @Test func aFloodWithNoClientBuildsNoSnapshot() async {
        let view = makeView()
        var builds = 0
        let snapshot = snapshot()
        view.accessibilitySnapshotProvider = {
            builds += 1
            return snapshot
        }
        for _ in 0..<1_000 {
            view.noteAccessibilityValueChanged()
            view.noteAccessibilitySelectionChanged()
        }
        #expect(builds == 0, "the synchronous posts carry no string")
        #expect(view.pendingAccessibilityPost != nil, "one trailing post is owed")
        await waitUntil("the trailing valueChanged post") { view.pendingAccessibilityPost == nil }
        #expect(builds == 0, "the trailing post carries no string either")
    }

    /// A client that does ask gets one snapshot per burst (the 0.2 s cache),
    /// and hearing a change makes its next read rebuild — the cache and the
    /// notification interval stay paired as before.
    @Test func theSnapshotIsBuiltOnlyWhenAClientAsks() {
        let view = makeView()
        var builds = 0
        let snapshot = snapshot()
        view.accessibilitySnapshotProvider = {
            builds += 1
            return snapshot
        }
        view.noteAccessibilityValueChanged()
        #expect(builds == 0, "posting builds no snapshot")
        _ = view.accessibilityValue()
        #expect(builds == 1)
        _ = view.accessibilityValue()
        #expect(builds == 1, "a client's burst is answered from one snapshot")
        view.noteAccessibilityValueChanged()
        _ = view.accessibilityValue()
        #expect(builds == 2, "a posted change makes the next read rebuild")
    }
}
