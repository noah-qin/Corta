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

import Foundation

/// The one command a worktree session may have typed for the user. Never run.
nonisolated enum WorktreeCommand {
    static func line(location: String, branch: String, newBranch: Bool) -> String? {
        guard token(location), token(branch) else { return nil }
        let place = quote(location)
        let name = quote(branch)
        if newBranch {
            return "git worktree add \(place) -b \(name) && cd \(place)"
        }
        return "git worktree add \(place) \(name) && cd \(place)"
    }

    static func location(projectPath: String, name: String) -> String? {
        guard token(name) else { return nil }
        let parent = (projectPath as NSString).deletingLastPathComponent
        let folder = (projectPath as NSString).lastPathComponent + "-" + name
        return (parent as NSString).appendingPathComponent(folder)
    }

    private static func token(_ text: String) -> Bool {
        (1...128).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 46 || byte == 95 || byte == 45 || byte == 47
        }
    }

    private static func quote(_ text: String) -> String { "'" + text + "'" }
}
