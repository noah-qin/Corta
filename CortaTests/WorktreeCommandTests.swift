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

struct WorktreeCommandTests {
    @Test func theLineIsOneShapeAndRejectsUnsafeNames() throws {
        let created = WorktreeCommand.line(location: "/work/app-topic", branch: "topic", newBranch: true)
        #expect(created == "git worktree add '/work/app-topic' -b 'topic' && cd '/work/app-topic'")
        let existing = WorktreeCommand.line(location: "/work/app-main", branch: "main", newBranch: false)
        #expect(existing == "git worktree add '/work/app-main' 'main' && cd '/work/app-main'")
        #expect(WorktreeCommand.line(location: "/work/app topic", branch: "main", newBranch: false) == nil)
        #expect(WorktreeCommand.line(location: "/work/app", branch: "ma;in", newBranch: true) == nil)
        #expect(WorktreeCommand.location(projectPath: "/work/app", name: "topic") == "/work/app-topic")
        let pattern = #"^git worktree add '[A-Za-z0-9._/-]+'( -b)? '[A-Za-z0-9._/-]+' && cd '[A-Za-z0-9._/-]+'$"#
        #expect(created?.wholeMatch(of: try Regex(pattern)) != nil)
    }
}
