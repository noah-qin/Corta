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

/// The parts of the release rules (`docs/RELEASING.md`) that are judgements
/// over text: the project file, the feed, the documents that name a
/// version. `corta-release-check` gathers the facts — it reads the bundle,
/// runs `codesign` and `lipo` — and asks these; keeping them apart from the
/// process launches is what lets them be tested without an app.
public enum ReleaseCheck {

    /// Every distinct value a build setting takes across the project's
    /// configurations, in first-seen order. More than one means the project
    /// disagrees with itself, and the check says so rather than picking one.
    public static func projectSetting(_ name: String, in pbxproj: String) -> [String] {
        var values: [String] = []
        for line in pbxproj.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix(name + " = ") else { continue }
            var value = trimmed.dropFirst(name.count + 3)
            if let end = value.firstIndex(of: ";") { value = value[..<end] }
            let unquoted = String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !values.contains(unquoted) { values.append(unquoted) }
        }
        return values
    }

    /// Sparkle orders updates by build number, so one that is not a plain
    /// integer makes an update invisible to everyone on the previous release.
    public static func isIntegerBuild(_ build: String) -> Bool {
        !build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether `CHANGELOG.md` has the `## [V]` heading the release notes link to.
    public static func changelogHasSection(_ changelog: String, version: String) -> Bool {
        changelog.split(separator: "\n").contains { $0.hasPrefix("## [\(version)]") }
    }

    /// The archive's file name for a version; the feed, the README and the
    /// release all name it this way.
    public static func archiveName(version: String) -> String { "Corta-\(version).zip" }

    /// A SHA-256 sidecar in `shasum -a 256` form, naming the archive by its
    /// file name so `shasum -c` works from the directory it is downloaded to.
    public static func sidecar(digest: String, archiveName: String) -> String {
        "\(digest)  \(archiveName)\n"
    }

    /// The digest a sidecar records: its first field.
    public static func recordedDigest(inSidecar text: String) -> String? {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
    }

    /// The fields of one feed item the release check compares with the app
    /// and the archive in hand. The feed's own rules — URLs, ordering,
    /// signatures — belong to `scripts/verify-appcast.swift`.
    public struct AppcastItem: Equatable, Sendable {
        public var build: String
        public var length: String
        public var hardwareRequirements: String

        public init(build: String, length: String, hardwareRequirements: String) {
            self.build = build
            self.length = length
            self.hardwareRequirements = hardwareRequirements
        }
    }

    public static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// The first item whose `sparkle:shortVersionString` is `version`, or nil.
    public static func appcastItem(version: String, in feed: Data) throws -> AppcastItem? {
        let document = try XMLDocument(data: feed)
        for item in try document.nodes(forXPath: "//item").compactMap({ $0 as? XMLElement }) {
            func text(_ local: String) -> String {
                item.elements(forLocalName: local, uri: sparkleNamespace).first?.stringValue ?? ""
            }
            guard text("shortVersionString") == version else { continue }
            let length = item.elements(forName: "enclosure").first?.attribute(forName: "length")?.stringValue
            return AppcastItem(build: text("version"), length: length ?? "",
                               hardwareRequirements: text("hardwareRequirements"))
        }
        return nil
    }

    /// Whether a `sparkle:hardwareRequirements` list names arm64 — what keeps
    /// an Intel Mac from being offered an app it cannot open (D21).
    public static func requiresArm64(_ requirements: String) -> Bool {
        requirements.split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "arm64" }
    }
}
