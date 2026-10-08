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

import CryptoKit
import Foundation
import ReleaseCheck

/// `corta-release-check` — the one packaging check (B15 / T11). The release
/// workflow, the update-feed workflow and a maintainer's local package all
/// run it rather than each carrying a copy of the rules, so a local package
/// and a CI package are rejected for the same reasons, and a rule added
/// here reaches every route at once.
///
///     corta-release-check check APP [--version V] [--archive ZIP]
///                                   [--appcast] [--require-notarized]
///     corta-release-check package APP VERSION [OUTPUT_DIRECTORY]
///                                   [--require-notarized] [--rehearsal]
///
/// `check`, always: the app's Info.plist agrees with project.pbxproj on the
/// marketing version, the build number and the deployment target; the
/// build number is an integer; every file carries its license header;
/// CHANGELOG.md has a heading for the version; README.md names the release
/// archive and the minimum macOS for it; the app's executable and
/// corta-exec are arm64 only (D21); the code signature verifies.
///
///     --version V          V (a tag with its `v` stripped) must be the version.
///     --archive ZIP        ZIP is named Corta-V.zip, holds Corta.app, its
///                          ZIP.sha256 sidecar matches it, and the feed and
///                          V's signature verify (scripts/verify-appcast.swift).
///     --appcast            appcast.xml has an item for this version and build
///                          whose enclosure length, with --archive, is the
///                          archive's; for an arm64-only app the item
///                          requires arm64.
///     --require-notarized  the signature is a Developer ID one, the
///                          notarization ticket is stapled, and Gatekeeper
///                          accepts the app.
///
/// `package` zips the app with `ditto` into OUTPUT_DIRECTORY (default
/// `dist`) as Corta-VERSION.zip, writes the SHA-256 sidecar beside it, and
/// runs the same checks on it — so an archive that would be rejected on CI
/// is rejected here first, for the same reason. One exception: the feed is
/// signed only after a release is published (D20), so a package has no
/// signature to verify yet. It checks the feed alone instead, and that the
/// feed does not already publish VERSION, whose signed bytes a rebuild would
/// never match.
///
///     --rehearsal          skip only that last rule, for release.yml's dry
///                          run, which rebuilds the version the project
///                          carries — usually one already published.
///
/// Run from the repository (or pass `--root`). Exit status is the number
/// of failed checks, and every failure is printed; 2 is a usage error.

let usage = """
    usage: corta-release-check check APP [--version V] [--archive ZIP] [--appcast]
                                         [--require-notarized] [--root DIR]
           corta-release-check package APP VERSION [OUTPUT_DIRECTORY]
                                         [--require-notarized] [--rehearsal] [--root DIR]
    """

func usageError(_ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("corta-release-check: \(message)\n".utf8)) }
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

// MARK: - Processes

struct Output {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs a tool and collects what it printed; nil when it could not start.
func run(_ executable: String, _ arguments: [String], in directory: String? = nil) -> Output? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    guard (try? process.run()) != nil else { return nil }
    // Drain both pipes before waiting, or a tool that fills one blocks forever.
    final class Collected: @unchecked Sendable { var data = Data() }
    let errors = Collected()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) { errors.data = err.fileHandleForReading.readDataToEndOfFile() }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    let errData = errors.data
    process.waitUntilExit()
    return Output(status: process.terminationStatus,
                  stdout: String(decoding: outData, as: UTF8.self),
                  stderr: String(decoding: errData, as: UTF8.self))
}

func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["check", "package"].contains(command) else { usageError() }
arguments.removeFirst()

var positional: [String] = []
var expectedVersion: String?
var archivePath: String?
var checkAppcast = false
var requireNotarized = false
var rootOverride: String?
var rehearsal = false
while let argument = arguments.first {
    arguments.removeFirst()
    func value() -> String {
        guard let value = arguments.first else { usageError("\(argument) needs a value") }
        arguments.removeFirst()
        return value
    }
    switch argument {
    case "--version" where command == "check": expectedVersion = value()
    case "--archive" where command == "check": archivePath = value()
    case "--appcast" where command == "check": checkAppcast = true
    case "--require-notarized": requireNotarized = true
    case "--rehearsal" where command == "package": rehearsal = true
    case "--root": rootOverride = value()
    case let flag where flag.hasPrefix("--"): usageError("unknown argument \(flag)")
    default: positional.append(argument)
    }
}

let fileManager = FileManager.default
let start = rootOverride ?? fileManager.currentDirectoryPath
guard let top = run("/usr/bin/git", ["-C", start, "rev-parse", "--show-toplevel"]), top.status == 0 else {
    usageError("\(start) is not inside the Corta repository; run from it or pass --root")
}
let root = trimmed(top.stdout)

@MainActor func absolute(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath + "/"))
        .standardizedFileURL.path
}

// MARK: - package

if command == "package" {
    guard (2...3).contains(positional.count) else { usageError() }
    let app = absolute(positional[0])
    let version = positional[1]
    let outputDirectory = absolute(positional.count == 3 ? positional[2] : "dist")
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: app, isDirectory: &isDirectory), isDirectory.boolValue else {
        FileHandle.standardError.write(Data("application not found: \(app)\n".utf8))
        exit(1)
    }
    try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    let name = ReleaseCheck.archiveName(version: version)
    let archive = "\(outputDirectory)/\(name)"
    try? fileManager.removeItem(atPath: archive)
    guard let ditto = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--sequesterRsrc", app, archive]),
          ditto.status == 0 else {
        FileHandle.standardError.write(Data("ditto could not archive \(app)\n".utf8))
        exit(1)
    }
    let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: archive), options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined()
    try ReleaseCheck.sidecar(digest: digest, archiveName: name)
        .write(toFile: archive + ".sha256", atomically: true, encoding: .utf8)
    positional = [app]
    expectedVersion = version
    archivePath = archive
}

guard positional.count == 1 else { usageError() }

// MARK: - check

let app = absolute(positional[0])
var failures = 0
@MainActor func fail(_ message: String) { print("FAIL  \(message)"); failures += 1 }
@MainActor func pass(_ message: String) { print("ok    \(message)") }
@MainActor func finish() -> Never {
    exit(Int32(min(failures, 125)))
}

let plistURL = URL(fileURLWithPath: "\(app)/Contents/Info.plist")
guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
    fail("no application bundle at \(app)")
    exit(1)
}
@MainActor func plistValue(_ key: String) -> String { (plist[key] as? String) ?? "" }

let pbxproj = (try? String(contentsOfFile: "\(root)/Corta.xcodeproj/project.pbxproj", encoding: .utf8)) ?? ""
@MainActor func projectSetting(_ name: String) -> String {
    let values = ReleaseCheck.projectSetting(name, in: pbxproj)
    if values.count != 1 {
        fail("\(name) has \(values.count) values in project.pbxproj: \(values.joined(separator: " "))")
    }
    return values.first ?? ""
}

let projectVersion = projectSetting("MARKETING_VERSION")
let projectBuild = projectSetting("CURRENT_PROJECT_VERSION")
let projectTarget = projectSetting("MACOSX_DEPLOYMENT_TARGET")
let bundleVersion = plistValue("CFBundleShortVersionString")
let bundleBuild = plistValue("CFBundleVersion")
let bundleTarget = plistValue("LSMinimumSystemVersion")

// --- Versions

if !bundleVersion.isEmpty, bundleVersion == projectVersion {
    pass("CFBundleShortVersionString \(bundleVersion) matches MARKETING_VERSION")
} else {
    fail("CFBundleShortVersionString '\(bundleVersion)' != MARKETING_VERSION '\(projectVersion)'")
}
if let expectedVersion {
    if bundleVersion == expectedVersion {
        pass("version matches the requested \(expectedVersion)")
    } else {
        fail("version '\(bundleVersion)' != requested '\(expectedVersion)' (is the tag right?)")
    }
}
if !bundleBuild.isEmpty, bundleBuild == projectBuild {
    pass("CFBundleVersion \(bundleBuild) matches CURRENT_PROJECT_VERSION")
} else {
    fail("CFBundleVersion '\(bundleBuild)' != CURRENT_PROJECT_VERSION '\(projectBuild)'")
}
if ReleaseCheck.isIntegerBuild(bundleBuild) {
    pass("build number is an integer")
} else {
    fail("build number '\(bundleBuild)' is not an integer Sparkle can compare")
}
if !bundleTarget.isEmpty, bundleTarget == projectTarget {
    pass("LSMinimumSystemVersion \(bundleTarget) matches MACOSX_DEPLOYMENT_TARGET")
} else {
    fail("LSMinimumSystemVersion '\(bundleTarget)' != MACOSX_DEPLOYMENT_TARGET '\(projectTarget)'")
}

// --- License headers

// `corta-license` is the one implementation of the header rules
// (docs/LICENSING.md); CI applies the same rules through `swift test`.
let license = run("/usr/bin/xcrun", ["swift", "run", "--package-path", "\(root)/CortaTerminal",
                                      "-c", "release", "-q", "corta-license", "check", "--root", root])
if license?.status == 0 {
    pass("every file carries its license header")
} else {
    fail("license headers (corta-license check):")
    for line in ((license?.stdout ?? "") + (license?.stderr ?? "")).split(separator: "\n") {
        print("      \(line)")
    }
}

// --- Documents that name the version

let changelog = (try? String(contentsOfFile: "\(root)/CHANGELOG.md", encoding: .utf8)) ?? ""
let readme = (try? String(contentsOfFile: "\(root)/README.md", encoding: .utf8)) ?? ""
let archiveName = ReleaseCheck.archiveName(version: bundleVersion)
if ReleaseCheck.changelogHasSection(changelog, version: bundleVersion) {
    pass("CHANGELOG.md has a [\(bundleVersion)] section")
} else {
    fail("CHANGELOG.md has no '## [\(bundleVersion)]' heading")
}
if readme.contains(archiveName) {
    pass("README.md names \(archiveName)")
} else {
    fail("README.md does not name \(archiveName) — its download instructions are stale")
}
if readme.contains("macOS \(bundleTarget)") {
    pass("README.md states the macOS \(bundleTarget) minimum")
} else {
    fail("README.md does not state 'macOS \(bundleTarget)' as the minimum")
}

// --- Architecture

// Apple silicon only (D21). Xcode does not apply the project's ARCHS to
// Swift package products, so a build that did not pass `ARCHS=arm64` on the
// command line ships a universal corta-exec beside an arm64 app. Sparkle's
// own binaries are not ours to thin; the rule covers the two executables
// this project compiles.
func architectures(_ path: String) -> String {
    trimmed(run("/usr/bin/lipo", ["-archs", path])?.stdout ?? "")
}
let bundleExecutable = plistValue("CFBundleExecutable")
let appArchitectures = architectures("\(app)/Contents/MacOS/\(bundleExecutable)")
for executable in [bundleExecutable, "corta-exec"] {
    let path = "\(app)/Contents/MacOS/\(executable)"
    guard !executable.isEmpty, fileManager.fileExists(atPath: path) else {
        fail("no executable at Contents/MacOS/\(executable.isEmpty ? "<CFBundleExecutable missing>" : executable)")
        continue
    }
    let archs = architectures(path)
    if archs == "arm64" {
        pass("\(executable) is arm64 only")
    } else {
        fail("\(executable) is built for '\(archs.isEmpty ? "unreadable" : archs)', not arm64 only (D21)")
    }
}

// --- Signature

if run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app])?.status == 0 {
    pass("code signature verifies")
} else {
    fail("codesign --verify --deep --strict failed for \(app)")
}

if requireNotarized {
    // codesign -d writes its description to standard error.
    let description = run("/usr/bin/codesign", ["-dvv", app])?.stderr ?? ""
    let authority = description.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map(String.init)
    if authority?.contains("Developer ID Application") == true {
        pass("signed with a Developer ID identity")
    } else {
        fail("not signed with a Developer ID identity: \(authority ?? "no authority")")
    }
    if run("/usr/bin/xcrun", ["stapler", "validate", app])?.status == 0 {
        pass("notarization ticket is stapled")
    } else {
        fail("no stapled notarization ticket (xcrun stapler validate)")
    }
    if run("/usr/sbin/spctl", ["--assess", "--type", "exec", app])?.status == 0 {
        pass("Gatekeeper accepts the app")
    } else {
        fail("spctl --assess rejects the app")
    }
}

// --- Hardened runtime, entitlements, load paths

/// Every Mach-O file in the bundle — the app, corta-exec, Sparkle and its
/// helpers (Autoupdate, Updater.app, the XPC services) — found by magic
/// number rather than listed, so a component a Sparkle update adds is held
/// to the same rules. Symlinks into a framework's versions count once.
@MainActor func machOFiles(in bundle: String) -> [String] {
    let magics: Set<UInt32> = [0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xFEED_FACE, 0xCEFA_EDFE]
    var seen = Set<String>()
    var found: [String] = []
    guard let walker = fileManager.enumerator(atPath: bundle) else { return [] }
    while let relative = walker.nextObject() as? String {
        let path = ("\(bundle)/\(relative)" as NSString).resolvingSymlinksInPath
        var isDirectory: ObjCBool = false
        guard !seen.contains(path), fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue, let handle = FileHandle(forReadingAtPath: path)
        else { continue }
        let head = handle.readData(ofLength: 4)
        handle.closeFile()
        let magic = head.reduce(UInt32(0), { $0 << 8 | UInt32($1) })
        guard head.count == 4, magics.contains(magic) else { continue }
        seen.insert(path)
        found.append(path)
    }
    return found.sorted()
}

// A component that can be debugged, load another team's libraries, honour
// DYLD_* or map writable executable memory inherits every TCC grant the app
// was given; so does one that searches a directory outside the bundle and
// the system for its libraries (SECURITY.md §4.2).
let resolvedApp = (app as NSString).resolvingSymlinksInPath
let components = machOFiles(in: app)
var entitlementProblems: [String] = []
var runtimeMissing: [String] = []
var componentsByTeam: [String: [String]] = [:]
var loadPathProblems: [String] = []
for path in components {
    let name = path.hasPrefix(resolvedApp + "/") ? String(path.dropFirst(resolvedApp.count + 1)) : path
    let entitlements = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path])?.stdout ?? ""
    if let denied = ReleaseCheck.forbiddenEntitlements(inPlist: Data(entitlements.utf8)) {
        entitlementProblems += denied.map { "\(name): \($0)" }
    } else {
        entitlementProblems.append("\(name): entitlements unreadable")
    }
    let description = run("/usr/bin/codesign", ["-dvv", path])?.stderr ?? ""
    if !ReleaseCheck.hasHardenedRuntime(codesignDescription: description) {
        runtimeMissing.append(name)
    }
    componentsByTeam[ReleaseCheck.teamIdentifier(codesignDescription: description) ?? "none", default: []]
        .append(name)
    let loads = ReleaseCheck.loadPaths(otoolLoadCommands: run("/usr/bin/otool", ["-l", path])?.stdout ?? "")
    loadPathProblems += ReleaseCheck.unsafeLoadPaths(loads).map { "\(name): \($0.command) \($0.path)" }
}
if components.isEmpty {
    fail("no Mach-O code found in \(app)")
}
if entitlementProblems.isEmpty {
    pass("no component carries a denied entitlement (\(components.count) checked)")
} else {
    fail("denied or unreadable entitlements:")
    for problem in entitlementProblems { print("      \(problem)") }
}
if runtimeMissing.isEmpty {
    pass("every component is signed with the hardened runtime")
} else {
    fail("signed without the hardened runtime: \(runtimeMissing.joined(separator: ", "))")
}
// Ad hoc builds carry no team at all, which is consistent; a release must
// carry exactly one, the Developer ID's.
let teams = componentsByTeam.keys.sorted()
if teams.count > 1 {
    fail("components disagree on the team identifier:")
    for team in teams { print("      \(team): \((componentsByTeam[team] ?? []).joined(separator: ", "))") }
} else if requireNotarized, teams.first == "none" {
    fail("no component carries a team identifier")
} else if let team = teams.first {
    pass("every component carries team identifier \(team)")
}
if loadPathProblems.isEmpty {
    pass("no component searches outside the bundle and the system for libraries")
} else {
    fail("load paths outside the bundle and the system:")
    for problem in loadPathProblems { print("      \(problem)") }
}

// --- Archive

var archiveLength: String?
if let archivePath {
    let archive = absolute(archivePath)
    let name = (archive as NSString).lastPathComponent
    if name == archiveName {
        pass("archive is named \(archiveName)")
    } else {
        fail("archive is named \(name), not \(archiveName)")
    }
    let listing = run("/usr/bin/zipinfo", ["-1", archive])?.stdout ?? ""
    if listing.split(separator: "\n").contains("Corta.app/Contents/Info.plist") {
        pass("archive contains Corta.app")
    } else {
        fail("archive \(archive) is missing or does not contain Corta.app at its root")
    }
    if let sidecar = try? String(contentsOfFile: archive + ".sha256", encoding: .utf8),
       let recorded = ReleaseCheck.recordedDigest(inSidecar: sidecar) {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: archive), options: .mappedIfSafe)) ?? Data()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if recorded == actual {
            pass("sha256 sidecar matches the archive")
        } else {
            fail("sha256 sidecar (\(recorded)) does not match the archive (\(actual))")
        }
    } else {
        fail("no \(name).sha256 beside the archive")
    }
    if let size = (try? fileManager.attributesOfItem(atPath: archive))?[.size] as? Int {
        archiveLength = String(size)
    }

    // The feed's own rules — every enclosure URL matching its version, build
    // numbers unique and newest-first, signatures well-formed — belong to
    // `verify-appcast.swift`, which `ci.yml` and `nightly.yml` also run.
    // What only this check can add is the archive in hand: presence is not
    // validity, and a signature made with a key whose public half is not the
    // shipped SUPublicEDKey is well-formed and rejected by every installed
    // Corta. So `check --archive` verifies V's signature over it, with or
    // without `--appcast`.
    //
    // `package` is the exception. It runs in release.yml before the release
    // is published, and the feed is signed only after that (D20), so there is
    // no signature for V yet: it verifies the feed alone, and that the feed
    // does not already publish V, whose signed bytes this archive would never
    // match.
    let packaging = command == "package"
    let feedArguments = packaging ? [] : ["--archive", archive, "--version", bundleVersion]
    let verify = run("/usr/bin/xcrun", ["swift", "\(root)/scripts/verify-appcast.swift",
                                        "\(root)/appcast.xml", "\(root)/Sparkle-Info.plist"]
                                        + feedArguments)
    for line in ((verify?.stdout ?? "") + (verify?.stderr ?? "")).split(separator: "\n") {
        print("      \(line)")
    }
    switch verify?.status {
    case 0?:
        pass(packaging
            ? "the feed verifies"
            : "the feed verifies, and \(bundleVersion)'s signature verifies under SUPublicEDKey")
    case nil, 2?, 126?, 127?:
        // Not a verdict on the signature: sending a maintainer after the
        // signing key when `swift` simply failed to start would be worse
        // than saying the feed went unchecked.
        fail("verify-appcast could not run (status \(verify.map { String($0.status) } ?? "none")); the feed was not checked")
    case let status?:
        fail("verify-appcast reported \(status) failed check(s) — its output is above")
    }
    if packaging {
        let feed = (try? Data(contentsOf: URL(fileURLWithPath: "\(root)/appcast.xml"))) ?? Data()
        switch Result(catching: { try ReleaseCheck.appcastItem(version: bundleVersion, in: feed) }) {
        case .success(nil):
            pass("appcast.xml does not publish \(bundleVersion) yet")
        case .success(.some) where rehearsal:
            print("skip  appcast.xml already publishes \(bundleVersion) — a rehearsal rebuilds it")
        case .success(.some):
            fail("appcast.xml already publishes \(bundleVersion); an archive built now is not the one it signed")
        case .failure(let error):
            fail("appcast.xml does not parse: \(error.localizedDescription)")
        }
    }
}

// --- Appcast

if checkAppcast {
    let feed = (try? Data(contentsOf: URL(fileURLWithPath: "\(root)/appcast.xml"))) ?? Data()
    switch Result(catching: { try ReleaseCheck.appcastItem(version: bundleVersion, in: feed) }) {
    case .failure(let error):
        fail("appcast.xml does not parse: \(error.localizedDescription)")
    case .success(nil):
        fail("appcast.xml has no item for version \(bundleVersion)")
    case .success(let item?):
        if item.build == bundleBuild {
            pass("appcast item carries build \(bundleBuild)")
        } else {
            fail("appcast item for \(bundleVersion) carries build '\(item.build)', app has \(bundleBuild)")
        }
        if let archiveLength {
            if item.length == archiveLength {
                pass("appcast enclosure length matches the archive (\(archiveLength) bytes)")
            } else {
                fail("appcast enclosure length \(item.length) != archive size \(archiveLength)")
            }
        }
        // What keeps an Intel Mac where it is (D21): Sparkle 2.9 and later —
        // every shipped Corta — does not offer an item whose
        // `sparkle:hardwareRequirements` names arm64 to a Mac without it.
        // generate_appcast writes the element when the executable has no
        // Intel slice; this holds the feed to it rather than trusting that.
        if appArchitectures == "arm64" {
            if ReleaseCheck.requiresArm64(item.hardwareRequirements) {
                pass("appcast item requires arm64 hardware")
            } else {
                fail("appcast item for \(bundleVersion) has no sparkle:hardwareRequirements arm64; Intel Macs would be offered an app they cannot open")
            }
        }
    }
}

if failures == 0 {
    print("corta-release-check: all checks passed for Corta \(bundleVersion) (\(bundleBuild))")
} else {
    print("corta-release-check: \(failures) check(s) failed")
}
if command == "package", let archivePath {
    print(archivePath)
    print(trimmed((try? String(contentsOfFile: archivePath + ".sha256", encoding: .utf8)) ?? ""))
}
finish()
