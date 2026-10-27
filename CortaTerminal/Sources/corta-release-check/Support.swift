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

// MARK: - Usage

let usage = """
    usage: corta-release-check check APP [--version V] [--archive DMG] [--appcast]
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

/// The architectures `lipo` reports for an executable.
func architectures(_ path: String) -> String {
    trimmed(run("/usr/bin/lipo", ["-archs", path])?.stdout ?? "")
}

// MARK: - Bundle contents

/// Every Mach-O file in the bundle — the app, corta-exec, Sparkle and its
/// helpers (Autoupdate, Updater.app, the XPC services) — found by magic
/// number rather than listed, so a component a Sparkle update adds is held
/// to the same rules. Symlinks into a framework's versions count once.
func machOFiles(in bundle: String) -> [String] {
    let magics: Set<UInt32> = [0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xFEED_FACE, 0xCEFA_EDFE]
    var seen = Set<String>()
    var found: [String] = []
    let fileManager = FileManager.default
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
