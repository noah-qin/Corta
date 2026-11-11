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

/// What output announcements need from the pane.
protocol PaneOutputAnnouncementHost: AnyObject {
    var session: TerminalSession! { get }
    var terminalView: TerminalView! { get }
    /// The focused pane of the tab in front (D30): the pane a reader is
    /// looking at.
    var holdsWindowFocus: Bool { get }
    /// Rows above the live bottom. A reader scrolled into history is reading
    /// and is not interrupted by a command finishing.
    var scrollOffset: Int { get }
}

/// Speaks a finished command's output to VoiceOver.
///
/// Only a command the shell said finished gets an announcement: a running
/// program's output is not a stream of lines to read, and prompt echo is
/// not divided into commands. Without OSC 133 command marks — a shell with
/// no Corta integration — nothing is announced, because there is no honest
/// boundary between what the user typed and what a program printed.
@MainActor
final class PaneOutputAnnouncements {
    private weak var host: PaneOutputAnnouncementHost?
    private var policy = OutputAnnouncementPolicy()

    init(host: PaneOutputAnnouncementHost? = nil) {
        self.host = host
    }

    /// Called once per finished command, from the output batch's one read of
    /// the command state.
    ///
    /// The assistive-technology check is first: with no VoiceOver running,
    /// no record, grid snapshot or string is built for this
    /// (`PERFORMANCE.md` §2). An announcement is speech in the user's ear,
    /// so a background tab, another window and a pane scrolled into history
    /// leave it out.
    func noteFinishedCommand(exitStatus: Int, commandID: Int) {
        guard NSWorkspace.shared.isVoiceOverEnabled,
            let host,
            host.holdsWindowFocus,
            host.scrollOffset == 0,
            host.terminalView?.window?.isKeyWindow == true,
            let session = host.session,
            let record = session.commandRecords.records.first(where: { $0.id == commandID })
        else { return }
        let grid = session.snapshot()
        guard
            let text = policy.announcement(
                grid: grid, record: record, exitStatus: exitStatus,
                isAlternateScreen: session.isAlternateScreenActive, now: CACurrentMediaTime())
        else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}
