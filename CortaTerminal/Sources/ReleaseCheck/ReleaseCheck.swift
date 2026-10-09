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
    public static func archiveName(version: String) -> String { "Corta-\(version).dmg" }

    public static func isDiskImageDownloadURL(_ url: String, version: String) -> Bool {
        url == diskImageDownloadURL(version: version)
    }

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
        public var url: String

        public init(build: String, length: String, hardwareRequirements: String, url: String = "") {
            self.build = build
            self.length = length
            self.hardwareRequirements = hardwareRequirements
            self.url = url
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
                               hardwareRequirements: text("hardwareRequirements"),
                               url: item.elements(forName: "enclosure").first?.attribute(forName: "url")?.stringValue ?? "")
        }
        return nil
    }

    /// Whether a `sparkle:hardwareRequirements` list names arm64 — what keeps
    /// an Intel Mac from being offered an app it cannot open (D21).
    public static func requiresArm64(_ requirements: String) -> Bool {
        requirements.split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "arm64" }
    }

    // MARK: - Code signatures and load paths

    /// Entitlements no shipped component may carry. Each switches off part of
    /// the hardened runtime — a debugger attaching, libraries not signed by
    /// the team, `DYLD_*` variables, writable executable memory — in an app
    /// whose TCC grants every child inherits (`SECURITY.md` §4.2).
    public static let deniedEntitlements = [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.debugger",
    ]

    /// The denied entitlements a `codesign -d --entitlements - --xml`
    /// plist grants, any value but `false` counting. An empty output is no
    /// entitlements; `nil` is output that is not a dictionary plist.
    public static func forbiddenEntitlements(inPlist data: Data) -> [String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let entitlements = object as? [String: Any]
        else { return nil }
        return deniedEntitlements.filter { key in
            guard let value = entitlements[key] else { return false }
            return (value as? Bool) != false
        }
    }

    /// Whether a `codesign -dvv` description's CodeDirectory carries the
    /// hardened runtime flag (`flags=0x10000(runtime)`, or among others).
    public static func hasHardenedRuntime(codesignDescription text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            guard line.hasPrefix("CodeDirectory "), let flags = line.range(of: "flags=") else {
                return false
            }
            let field = line[flags.upperBound...].prefix { $0 != " " }
            guard let open = field.firstIndex(of: "("), let close = field.lastIndex(of: ")"),
                open < close
            else { return false }
            return field[field.index(after: open)..<close].split(separator: ",").contains("runtime")
        }
    }

    /// The `TeamIdentifier=` of a `codesign -dvv` description; `nil` for an
    /// ad hoc signature (`not set`) or none.
    public static func teamIdentifier(codesignDescription text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count)
            return value.isEmpty || value == "not set" ? nil : String(value)
        }
        return nil
    }

    /// One search path or library a Mach-O load command names.
    public struct LoadPath: Equatable, Sendable {
        public var command: String
        public var path: String

        public init(command: String, path: String) {
            self.command = command
            self.path = path
        }
    }

    /// The `path` and `name` fields of `otool -l`'s load commands, each with
    /// the command it belongs to.
    public static func loadPaths(otoolLoadCommands text: String) -> [LoadPath] {
        var paths: [LoadPath] = []
        var command: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cmd ") {
                command = String(line.dropFirst(4))
                continue
            }
            guard let current = command, line.hasPrefix("path ") || line.hasPrefix("name ") else {
                continue
            }
            var value = line.dropFirst(5)
            if let offset = value.range(of: " (offset ", options: .backwards) {
                value = value[..<offset.lowerBound]
            }
            paths.append(LoadPath(command: current, path: String(value)))
            command = nil
        }
        return paths
    }

    /// Load paths that could resolve outside the bundle and the system's
    /// SIP-protected libraries — an `LC_RPATH` or library in a directory the
    /// user (or anyone who can write there) controls is a library the
    /// component would load in place of its own.
    public static func unsafeLoadPaths(_ paths: [LoadPath]) -> [LoadPath] {
        let system = ["/System/", "/usr/lib/"]
        let relative = ["@executable_path/", "@loader_path/"]
        func isSystem(_ path: String) -> Bool { system.contains { path.hasPrefix($0) } }
        func isRelative(_ path: String) -> Bool {
            path == "@executable_path" || path == "@loader_path" || relative.contains { path.hasPrefix($0) }
        }
        return paths.filter { item in
            switch item.command {
            case "LC_RPATH":
                return !(isRelative(item.path) || isSystem(item.path))
            case "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB",
                "LC_LAZY_LOAD_DYLIB":
                return !(item.path.hasPrefix("@rpath/") || isRelative(item.path) || isSystem(item.path))
            default:
                return false
            }
        }
    }
}
