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
import Testing

@testable import CortaTerminal

/// `CortaTerminal` must not import AppKit or Metal (`DESIGN.md` §4).
/// The core is a headless library: it is what makes the parser and grid
/// testable and benchmarkable without launching an app, and what keeps the
/// renderer on the far side of a snapshot boundary.
@Suite("Module boundary")
struct ModuleBoundaryTests {
    /// Frameworks that would drag the core back into the UI process.
    static let forbiddenModules = [
        "AppKit", "UIKit", "SwiftUI", "Metal", "MetalKit",
        "QuartzCore", "CoreGraphics", "CoreText", "Cocoa",
    ]

    static var sourceFiles: [URL] {
        // …/Tests/CortaTerminalTests/ModuleBoundaryTests.swift → …/Sources/CortaTerminal
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CortaTerminal")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "swift" }
    }

    @Test("the core imports no UI or GPU framework")
    func coreImportsNoUIFramework() throws {
        let files = Self.sourceFiles
        // Guard against a path mistake silently passing this test.
        #expect(files.count >= 4, "expected to find the core's sources")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = String(trimmed.dropFirst("import ".count))
                    .trimmingCharacters(in: .whitespaces)
                #expect(
                    !Self.forbiddenModules.contains(module),
                    "\(file.lastPathComponent) imports \(module)"
                )
            }
        }
    }
}
