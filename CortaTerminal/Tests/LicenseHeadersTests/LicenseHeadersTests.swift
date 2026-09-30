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

@testable import LicenseHeaders

@Suite("License header text")
struct LicenseHeaderTextTests {
    @Test("the header is the Apache appendix, framed by copyright and SPDX lines")
    func headerShape() {
        let lines = LicenseHeaders.header(year: 2026, style: .slashes)
        #expect(lines.count == 15)
        #expect(lines.first == "// Copyright 2026 Noah Qin")
        // REUSE-IgnoreStart
        #expect(lines.last == "// SPDX-License-Identifier: Apache-2.0")
        // REUSE-IgnoreEnd
        #expect(lines[1] == "//")
        #expect(lines[6] == "//     http://www.apache.org/licenses/LICENSE-2.0")
        #expect(!lines.contains { $0.hasSuffix(" ") })
    }

    @Test("the appendix text matches the LICENSE file word for word")
    func bodyMatchesLicense() throws {
        let license = try String(contentsOf: Repository.root.appendingPathComponent("LICENSE"), encoding: .utf8)
        let appendix = license.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for line in LicenseHeaders.body where !line.isEmpty {
            #expect(appendix.contains(line.trimmingCharacters(in: .whitespaces)), "\(line)")
        }
    }

    @Test("the hash style uses # and bare # for empty lines")
    func hashStyle() {
        let lines = LicenseHeaders.header(year: 2027, style: .hash)
        #expect(lines.first == "# Copyright 2027 Noah Qin")
        #expect(lines[1] == "#")
    }
}

@Suite("License header rules")
struct LicenseHeaderRuleTests {
    @Test(
        "each kind of file is classified",
        arguments: [
            ("Corta/AppDelegate.swift", LicenseHeaders.Treatment.header(.slashes)),
            ("CortaTerminal/Package.swift", .header(.slashes)),
            ("Corta/Renderer/Shaders.metal", .header(.slashes)),
            ("scripts/release.sh", .header(.hash)),
            ("scripts/example.py", .header(.hash)),
            (".github/workflows/ci.yml", .header(.hash)),
            (".gitignore", .header(.hash)),
            ("README.md", .reuse),
            ("docs/history/ROADMAP-0.1.md", .reuse),
            ("CortaTerminal/Tests/CortaTerminalTests/Golden/sgr.in", .reuse),
            ("CortaTerminal/Tests/Fuzz/corpus/seed-1.bin", .reuse),
            ("docs/brand/corta-pangolin-mascot.png", .reuse),
            ("docs/brand/social-preview.swift", .header(.slashes)),
            ("Corta/Acknowledgements/Sparkle-LICENSE.txt", .reuse),
            ("AppIcon.icon/icon.json", .reuse),
            ("Corta.xcodeproj/project.pbxproj", .reuse),
            ("LICENSE", .excluded),
            ("LICENSES/LicenseRef-Corta-Brand.txt", .excluded),
        ])
    func classification(path: String, expected: LicenseHeaders.Treatment) {
        #expect(LicenseHeaders.treatment(for: path) == expected)
    }

    @Test("a file no rule knows is unclassified, not passed")
    func unknownKind() {
        #expect(LicenseHeaders.treatment(for: "Corta/something.rb") == nil)
        #expect(LicenseHeaders.treatment(for: "notes.txt") == nil)
    }

    @Test("globs: * stays in a directory, ** crosses them and may match none")
    func globs() {
        #expect(Glob.matches("**/*.md", "README.md"))
        #expect(Glob.matches("**/*.md", "docs/history/a.md"))
        #expect(Glob.matches("TestPlans/*.xctestplan", "TestPlans/Unit.xctestplan"))
        #expect(!Glob.matches("TestPlans/*.xctestplan", "TestPlans/x/Unit.xctestplan"))
        #expect(Glob.matches("docs/brand/**", "docs/brand/a/b.png"))
        #expect(!Glob.matches("docs/brand/**", "docs/brandnew.png"))
        #expect(!Glob.matches("*.swift", "Corta/A.swift"))
    }
}

@Suite("Checking a header")
struct LicenseHeaderCheckTests {
    private static func file(year: Int = 2026, style: LicenseHeaders.CommentStyle = .slashes, body: String = "import Foundation\n") -> String {
        LicenseHeaders.header(year: year, style: style).joined(separator: "\n") + "\n\n" + body
    }

    @Test("the standard header passes")
    func standardPasses() {
        #expect(LicenseHeaders.check(Self.file(), style: .slashes, currentYear: 2026) == nil)
    }

    @Test("a file created in a later year may carry that year")
    func laterYearPasses() {
        #expect(LicenseHeaders.check(Self.file(year: 2028), style: .slashes, currentYear: 2028) == nil)
    }

    @Test("no header is missing")
    func noHeader() {
        #expect(LicenseHeaders.check("import Foundation\n", style: .slashes, currentYear: 2026) == .missing)
    }

    @Test(
        "a year range, a future year or a year before the repository is malformed",
        arguments: ["2026-2027", "2031", "2025"])
    func badYears(year: String) {
        let text = Self.file().replacingOccurrences(of: "Copyright 2026", with: "Copyright \(year)")
        guard case .malformed = LicenseHeaders.check(text, style: .slashes, currentYear: 2027) else {
            Issue.record("\(year) was accepted")
            return
        }
    }

    @Test("an altered line of the body is malformed, not missing")
    func alteredBody() {
        let text = Self.file().replacingOccurrences(of: "http://", with: "https://")
        guard case .malformed = LicenseHeaders.check(text, style: .slashes, currentYear: 2026) else {
            Issue.record("an altered URL was accepted")
            return
        }
    }

    @Test("the header must be followed by a blank line")
    func blankLineAfter() {
        let text = LicenseHeaders.header(year: 2026, style: .slashes).joined(separator: "\n") + "\nimport Foundation\n"
        guard case .malformed = LicenseHeaders.check(text, style: .slashes, currentYear: 2026) else {
            Issue.record("a header running into code was accepted")
            return
        }
    }

    @Test("a shebang and a swift-tools-version line stay above the header")
    func preludes() {
        let script = "#!/bin/bash\n" + Self.file(style: .hash, body: "set -eu\n")
        #expect(LicenseHeaders.check(script, style: .hash, currentYear: 2026) == nil)
        let manifest = "// swift-tools-version: 6.2\n" + Self.file(body: "import PackageDescription\n")
        #expect(LicenseHeaders.check(manifest, style: .slashes, currentYear: 2026) == nil)
    }
}

@Suite("Fixing a header")
struct LicenseHeaderFixTests {
    private static let header = LicenseHeaders.header(year: 2026, style: .slashes).joined(separator: "\n")

    @Test("a missing header is added, followed by one blank line")
    func adds() throws {
        let fixed = try #require(LicenseHeaders.fixed("\n\nimport Foundation\n", style: .slashes, year: 2026, currentYear: 2026))
        #expect(fixed == Self.header + "\n\nimport Foundation\n")
    }

    @Test("fixing twice changes nothing the second time")
    func idempotent() throws {
        let once = try #require(LicenseHeaders.fixed("let x = 1\n", style: .slashes, year: 2026, currentYear: 2026))
        #expect(LicenseHeaders.fixed(once, style: .slashes, year: 2026, currentYear: 2026) == nil)
        #expect(LicenseHeaders.check(once, style: .slashes, currentYear: 2026) == nil)
    }

    @Test("an Xcode template header is replaced, not kept beside the new one")
    func replacesXcodeTemplate() throws {
        let template = "//\n//  AppDelegate.swift\n//  Corta\n//\n//  Created by Noah on 9/1/26.\n//\n\nimport Cocoa\n"
        let fixed = try #require(LicenseHeaders.fixed(template, style: .slashes, year: 2026, currentYear: 2026))
        #expect(fixed == Self.header + "\n\nimport Cocoa\n")
    }

    @Test("an ordinary leading comment is kept, below the header")
    func keepsOrdinaryComment() throws {
        let fixed = try #require(LicenseHeaders.fixed("// Reports the GPU families.\nimport Metal\n", style: .slashes, year: 2026, currentYear: 2026))
        #expect(fixed == Self.header + "\n\n// Reports the GPU families.\nimport Metal\n")
    }

    @Test("the shebang stays the first line")
    func shebang() throws {
        let fixed = try #require(LicenseHeaders.fixed("#!/bin/bash\nset -eu\n", style: .hash, year: 2026, currentYear: 2026))
        let lines = fixed.components(separatedBy: "\n")
        #expect(lines[0] == "#!/bin/bash")
        #expect(lines[1] == "# Copyright 2026 Noah Qin")
        #expect(lines[16] == "")
        #expect(lines[17] == "set -eu")
    }

    @Test("swift-tools-version stays the manifest's first line")
    func manifest() throws {
        let fixed = try #require(LicenseHeaders.fixed("// swift-tools-version: 6.2\n\nimport PackageDescription\n", style: .slashes, year: 2026, currentYear: 2026))
        #expect(fixed.hasPrefix("// swift-tools-version: 6.2\n// Copyright 2026 Noah Qin\n"))
        #expect(LicenseHeaders.check(fixed, style: .slashes, currentYear: 2026) == nil)
    }

    @Test("a malformed header is left for a person")
    func leavesMalformed() {
        let text = Self.header.replacingOccurrences(of: "2026", with: "2026-2027") + "\n\nlet x = 1\n"
        #expect(LicenseHeaders.fixed(text, style: .slashes, year: 2026, currentYear: 2027) == nil)
    }

    @Test("the year written is the one asked for")
    func year() throws {
        let fixed = try #require(LicenseHeaders.fixed("let x = 1\n", style: .slashes, year: 2027, currentYear: 2027))
        #expect(fixed.hasPrefix("// Copyright 2027 Noah Qin\n"))
    }
}

/// Every file in the repository, held to the rules — the check CI runs,
/// since `swift test --package-path CortaTerminal` is part of every CI run.
@Suite("Repository license headers")
struct RepositoryLicenseHeaderTests {
    @Test("every file is classified, and every file that needs a header has the standard one")
    func everyFile() throws {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        var failures: [String] = []
        for path in try Repository.files() {
            guard let treatment = LicenseHeaders.treatment(for: path) else {
                failures.append("\(path): no rule classifies this file")
                continue
            }
            guard case .header(let style) = treatment else { continue }
            let text = try String(contentsOf: Repository.root.appendingPathComponent(path), encoding: .utf8)
            if let finding = LicenseHeaders.check(text, style: style, currentYear: year) {
                failures.append("\(path): \(finding)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) file(s):\n\(failures.joined(separator: "\n"))")
    }
}

enum Repository {
    /// The checkout this test file lives in.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LicenseHeadersTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // CortaTerminal
        .deletingLastPathComponent()

    /// The files git tracks, that still exist in the working tree.
    static func files() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0").map(String.init)
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
}
