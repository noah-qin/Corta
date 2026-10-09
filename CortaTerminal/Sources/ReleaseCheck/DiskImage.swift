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

extension ReleaseCheck {
    /// Root contents are an installable app and the drag-to-install link only.
    public static func diskImageLayoutProblems(entries: [String], appIsDirectory: Bool,
                                                applicationsTarget: String?, readOnly: Bool) -> [String] {
        var problems: [String] = []
        if entries.sorted() != ["Applications", "Corta.app"] {
            problems.append("disk image root must contain only Corta.app and Applications")
        }
        if !appIsDirectory { problems.append("Corta.app must be a directory, not a symlink") }
        if applicationsTarget != "/Applications" {
            problems.append("Applications must be a symlink to /Applications")
        }
        if !readOnly { problems.append("disk image must be mounted read-only") }
        return problems
    }

    /// Unknown image metadata is not evidence that no license dialog exists.
    public static func diskImageHasLicense(in data: Data) -> Bool? {
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any],
              let properties = dictionary["Properties"] as? [String: Any]
        else { return nil }
        return properties["Software License Agreement"] as? Bool
    }

    public static func diskImageDownloadURL(version: String) -> String {
        "https://github.com/noah-qin/Corta/releases/download/v\(version)/\(archiveName(version: version))"
    }

    public static func diskImageTeamMatches(_ imageTeam: String, appTeams: [String]) -> Bool {
        !imageTeam.isEmpty && appTeams == [imageTeam]
    }

    public struct ImageToolOutput {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
            self.status = status; self.stdout = stdout; self.stderr = stderr
        }
    }

    public typealias ImageToolRunner = (String, [String]) -> ImageToolOutput

    public static func runImageTool(_ executable: String, _ arguments: [String]) -> ImageToolOutput {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch {
            return ImageToolOutput(status: -1, stderr: Data(error.localizedDescription.utf8))
        }
        final class Collected: @unchecked Sendable { var data = Data() }
        let errors = Collected(), group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errors.data = err.fileHandleForReading.readDataToEndOfFile() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait(); process.waitUntilExit()
        return ImageToolOutput(status: process.terminationStatus, stdout: data, stderr: errors.data)
    }

    public struct ImageFailure: Error, LocalizedError {
        public let problems: [String]
        public var errorDescription: String? { problems.joined(separator: "; ") }
    }

    /// Owned mounts are detached explicitly before the command exits. A caller
    /// mount (appcast.yml's trap) is reused, and remains the caller's responsibility.
    public final class DiskImageMount {
        public let root: URL
        public let team: String
        private let scratch: URL?
        private let runner: ImageToolRunner
        private var closed = false
        init(root: URL, team: String, scratch: URL?, runner: @escaping ImageToolRunner) {
            self.root = root; self.team = team; self.scratch = scratch; self.runner = runner
        }
        public func close() -> Bool {
            if closed { return true }
            guard let scratch else { closed = true; return true }
            let normal = runner("/usr/bin/hdiutil", ["detach", root.path])
            if normal.status != 0 && runner("/usr/bin/hdiutil", ["detach", "-force", root.path]).status != 0 {
                return false
            }
            closed = true
            try? FileManager.default.removeItem(at: scratch)
            return true
        }
    }

    /// Verify the image before mounting it. All new disk-image judgments live
    /// here, shared by package, feed validation and local checks (D26).
    public static func inspectDiskImage(_ image: URL,
                                       runner: @escaping ImageToolRunner = runImageTool) throws -> DiskImageMount {
        var problems: [String] = []
        if runner("/usr/bin/codesign", ["--verify", "--strict", image.path]).status != 0 {
            problems.append("disk image code signature does not verify")
        }
        let description = String(decoding: runner("/usr/bin/codesign", ["-dvv", image.path]).stderr, as: UTF8.self)
        let team = teamIdentifier(codesignDescription: description)
        if !description.split(separator: "\n").contains(where: { $0.hasPrefix("Authority=Developer ID Application") }) || team == nil {
            problems.append("disk image must have a Developer ID Application signature and team")
        }
        if runner("/usr/bin/xcrun", ["stapler", "validate", image.path]).status != 0 {
            problems.append("disk image has no valid stapled notarization ticket")
        }
        if runner("/usr/sbin/spctl", ["-a", "-t", "open", "--context", "context:primary-signature", image.path]).status != 0 {
            problems.append("Gatekeeper rejects the disk image")
        }
        let metadata = runner("/usr/bin/hdiutil", ["imageinfo", "-plist", image.path])
        if metadata.status != 0 || diskImageHasLicense(in: metadata.stdout) != false {
            problems.append("disk image has a license agreement or unreadable license metadata")
        }
        guard problems.isEmpty, let team else { throw ImageFailure(problems: problems) }

        // Reuse only a read-only mount that hdiutil associates with these bytes.
        // This avoids attaching the same volume twice in the feed workflow.
        let info = runner("/usr/bin/hdiutil", ["info", "-plist"])
        var root: URL?
        if info.status == 0,
           let object = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil),
           let dictionary = object as? [String: Any], let images = dictionary["images"] as? [[String: Any]] {
            for item in images {
                guard let path = item["image-path"] as? String,
                      URL(fileURLWithPath: path).resolvingSymlinksInPath() == image.resolvingSymlinksInPath(),
                      let entities = item["system-entities"] as? [[String: Any]] else { continue }
                for entity in entities {
                    guard let path = entity["mount-point"] as? String else { continue }
                    let candidate = URL(fileURLWithPath: path)
                    if (try? candidate.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
                        root = candidate; break
                    }
                }
            }
        }
        var scratch: URL?
        if root == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corta-image-" + UUID().uuidString)
            let mount = directory.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let attached = runner("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
            if attached.status != 0 {
                // A failed attach can still have reached the mount stage.
                let detached = runner("/usr/bin/hdiutil", ["detach", mount.path])
                let safe = detached.status == 0 || runner("/usr/bin/hdiutil", ["detach", "-force", mount.path]).status == 0
                if safe {
                    try? FileManager.default.removeItem(at: directory)
                } else {
                    // rmdir removes only empty directories, never a mounted tree.
                    _ = runner("/bin/rmdir", [mount.path])
                    _ = runner("/bin/rmdir", [directory.path])
                }
                throw ImageFailure(problems: ["could not mount disk image read-only"])
            }
            root = mount; scratch = directory
        }
        guard let root else { throw ImageFailure(problems: ["no disk image mount"] ) }
        let mount = DiskImageMount(root: root, team: team, scratch: scratch, runner: runner)
        let entries = try? FileManager.default.contentsOfDirectory(atPath: mount.root.path)
        let app = mount.root.appendingPathComponent("Corta.app")
        let appType = (try? FileManager.default.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: mount.root.appendingPathComponent("Applications").path)
        let readOnly = (try? mount.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        let layout = diskImageLayoutProblems(entries: entries ?? [], appIsDirectory: appType == .typeDirectory,
                                              applicationsTarget: link, readOnly: readOnly)
        if !layout.isEmpty {
            let cleanup = mount.close() ? [] : ["could not detach disk image at " + mount.root.path]
            throw ImageFailure(problems: layout + cleanup)
        }
        return mount
    }
}
