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
import Foundation

/// The rule for reading a finished command's output aloud, and the only
/// place that decides what VoiceOver is told. Pure and passed the clock, so
/// a test drives it with no assistive client and no waiting.
///
/// The announcement is per *command*, never per appended line: command
/// marks say when one ends, so a build that prints for a minute says one
/// sentence at the end and a `yes` flood cannot queue minutes of speech.
/// Typing at the prompt arrives from the PTY as output too, but it sits
/// above the mark that starts a command's output, so it is never read back
/// here.
nonisolated struct OutputAnnouncementPolicy {
    /// Output longer than either bound is summarised instead of read: a
    /// flood such as `yes` is one bounded sentence, not the tail of a
    /// stream a person would have to sit through.
    let maximumRows: Int
    let maximumCharacters: Int
    /// The shortest gap between two announcements. A command finishing
    /// sooner is dropped, never queued, because speech that is minutes
    /// behind is worse than silence.
    let minimumInterval: TimeInterval

    /// `nil` until something is spoken.
    private var lastSpokenAt: TimeInterval?

    init(maximumRows: Int = 8, maximumCharacters: Int = 400, minimumInterval: TimeInterval = 2) {
        self.maximumRows = max(0, maximumRows)
        self.maximumCharacters = max(0, maximumCharacters)
        self.minimumInterval = max(0, minimumInterval)
    }

    /// What to speak for one finished command, or nil to stay silent.
    mutating func announcement(
        grid: Grid, record: CommandRecord, exitStatus: Int, isAlternateScreen: Bool,
        now: TimeInterval
    ) -> String? {
        // A full-screen program is not a stream of appended lines; its
        // screen is the user's to navigate, so a command that left one
        // active says nothing.
        guard !isAlternateScreen else { return nil }
        if let lastSpokenAt, now - lastSpokenAt < minimumInterval { return nil }
        guard
            let text = Self.text(
                grid: grid, record: record, exitStatus: exitStatus,
                maximumRows: maximumRows, maximumCharacters: maximumCharacters)
        else { return nil }
        lastSpokenAt = now
        return text
    }

    /// The text alone, without the rate limit; nil means silence. Separate
    /// so a test can check the wording with a fresh policy each time.
    static func text(
        grid: Grid, record: CommandRecord, exitStatus: Int,
        maximumRows: Int = 8, maximumCharacters: Int = 400
    ) -> String? {
        guard let range = PaneShellIntegration.commandOutputRange(grid: grid, record: record)
        else {
            // A command that printed nothing: a success has nothing to say,
            // a failure has its status.
            return exitStatus == 0 ? nil : failure(exitStatus)
        }
        // Counted before the text is built, so a flood costs one comparison
        // rather than a copy into a string that would be thrown away.
        let rows = range.end.row - range.start.row + 1
        if rows > maximumRows { return summary(exitStatus) }
        let output = Selection.text(of: range, in: grid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return exitStatus == 0 ? nil : failure(exitStatus) }
        if output.count > maximumCharacters { return summary(exitStatus) }
        return exitStatus == 0 ? output : output + "\n" + failure(exitStatus)
    }

    private static func failure(_ exitStatus: Int) -> String {
        L10n.format("a11y.command.failed", Int(exitStatus))
    }

    private static func summary(_ exitStatus: Int) -> String {
        let summary = L10n.text("a11y.command.outputTooLong")
        return exitStatus == 0 ? summary : summary + "\n" + failure(exitStatus)
    }
}
