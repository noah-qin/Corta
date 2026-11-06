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

/// Source-tree fixtures are read from the checkout, independently of a test's
/// directory and the test host's working directory. Keep path discovery here.
enum TestPaths {
    static let repositoryRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Corta.xcodeproj/project.pbxproj").path)
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        preconditionFailure("Cannot locate the Corta checkout from \(#filePath)")
    }()

    static let renderReferences = repositoryRoot
        .appendingPathComponent("CortaTests/Renderer/RenderReferences")
}
