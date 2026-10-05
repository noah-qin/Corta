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

/// `CortaTerminal` and `CortaSFTP` must not import AppKit or Metal
/// (`DESIGN.md` §4), nor each other.
/// The core is a headless library: it is what makes the parser and grid
/// testable and benchmarkable without launching an app, and what keeps the
/// renderer on the far side of a snapshot boundary. The SFTP client is the
/// core's sibling, not part of it; a dependency either way would make Xcode
/// link the core into the app twice over and turn it into a dynamic
/// framework.
@Suite("Module boundary")
struct ModuleBoundaryTests {
    /// Frameworks that would drag a library back into the UI process.
    static let forbiddenModules: Set<String> = [
        "AppKit", "UIKit", "SwiftUI", "Metal", "MetalKit",
        "QuartzCore", "CoreGraphics", "CoreText", "Cocoa",
    ]

    /// Every Swift file under `Sources/<target>`, subdirectories included.
    static func sourceFiles(of target: String) -> [URL] {
        // …/Tests/CortaTerminalTests/ModuleBoundaryTests.swift → …/Sources/<target>
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)")
        let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        )
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    /// The modules `file` imports, whatever the import's attributes, access
    /// level or kind (`@testable import X`, `internal import X`,
    /// `import struct X.Y`).
    static func importedModules(in file: URL) throws -> [String] {
        let declarationKinds: Set<Substring> = [
            "struct", "class", "enum", "protocol", "typealias", "func", "let", "var",
        ]
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard let index = words.firstIndex(of: "import") else { return nil }
            // Only attributes and access levels may come before `import`.
            let prefix = words[..<index]
            guard prefix.allSatisfy({
                $0.hasPrefix("@") || ["public", "package", "internal", "fileprivate", "private"]
                    .contains($0)
            }) else { return nil }
            var rest = words[(index + 1)...]
            if let kind = rest.first, declarationKinds.contains(kind) { rest = rest.dropFirst() }
            guard let path = rest.first else { return nil }
            return String(path.split(separator: ".").first ?? path)
        }
    }

    @Test(
        "a library imports no UI or GPU framework",
        arguments: ["CortaTerminal", "CortaSFTP"]
    )
    func libraryImportsNoUIFramework(target: String) throws {
        let files = Self.sourceFiles(of: target)
        // Guard against a path mistake silently passing this test.
        #expect(files.count >= 4, "expected to find \(target)'s sources")

        for file in files {
            for module in try Self.importedModules(in: file) {
                #expect(
                    !Self.forbiddenModules.contains(module),
                    "\(file.lastPathComponent) imports \(module)"
                )
            }
        }
    }

    @Test(
        "the core and the SFTP client do not import each other",
        arguments: [("CortaTerminal", "CortaSFTP"), ("CortaSFTP", "CortaTerminal")]
    )
    func librariesDoNotImportEachOther(target: String, sibling: String) throws {
        let files = Self.sourceFiles(of: target)
        #expect(files.count >= 4, "expected to find \(target)'s sources")

        for file in files {
            #expect(
                try !Self.importedModules(in: file).contains(sibling),
                "\(file.lastPathComponent) imports \(sibling)"
            )
        }
    }

    @Test("the import scan sees every spelling of an import")
    func importScanSeesEverySpelling() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuleBoundaryTests-\(UUID().uuidString).swift")
        try """
            import Foundation
            @testable import CortaSFTP
            internal import AppKit
            @preconcurrency public import Metal
            import struct SwiftUI.Color
            // import CoreText
            let important = "import Cocoa"
            """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(
            try Self.importedModules(in: file)
                == ["Foundation", "CortaSFTP", "AppKit", "Metal", "SwiftUI"]
        )
    }
}
