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
import LicenseHeaders

/// `corta-license` — checks and adds the Apache-2.0 header every source file
/// carries (`docs/LICENSING.md`).
///
///     swift run --package-path CortaTerminal corta-license check
///     swift run --package-path CortaTerminal corta-license fix [--year N] [path ...]
///
/// `check` exits non-zero if any file that needs a header lacks one, has a
/// non-standard one, or is of a kind no rule classifies. `fix` adds the
/// header, with the current year, to every file that lacks one; it never
/// rewrites a correct header or touches a malformed one, so running it
/// twice changes nothing the second time. `check` looks at the files git
/// tracks; `fix` also at untracked files that are not ignored, so a file
/// created a moment ago gets its header before it is committed.

let usage = """
    usage: corta-license check [--root <dir>]
           corta-license fix [--root <dir>] [--year <yyyy>] [path ...]
    """

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["check", "fix"].contains(command) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
arguments.removeFirst()

let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
var root = FileManager.default.currentDirectoryPath
var year = currentYear
var only: [String] = []
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--root":
        guard let value = arguments.first else { FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2) }
        root = value
        arguments.removeFirst()
    case "--year":
        guard let value = arguments.first.flatMap(Int.init) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        year = value
        arguments.removeFirst()
    default:
        only.append(argument)
    }
}

/// Runs git in `directory`; its standard output on success.
func git(_ arguments: [String], in directory: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
}

guard let top = git(["rev-parse", "--show-toplevel"], in: root)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
else {
    FileHandle.standardError.write(Data("corta-license: \(root) is not inside a git repository\n".utf8))
    exit(2)
}

// `check` judges what is committed: a release or CI job leaves build
// products (archives, unpacked apps) in the checkout that are neither
// tracked nor ignored, and they are not the repository's files. `fix` also
// takes untracked files, so a file created a moment ago gets its header
// before it is committed.
let listArguments = command == "fix"
    ? ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    : ["ls-files", "-z", "--cached"]
guard let listed = git(listArguments, in: top) else {
    FileHandle.standardError.write(Data("corta-license: git ls-files failed in \(top)\n".utf8))
    exit(2)
}
var paths = listed.split(separator: "\0").map(String.init)
    .filter { FileManager.default.fileExists(atPath: "\(top)/\($0)") }
if !only.isEmpty {
    let wanted = Set(only.map { path -> String in
        let absolute = path.hasPrefix("/") ? path : "\(FileManager.default.currentDirectoryPath)/\(path)"
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        return standardized.hasPrefix(top + "/") ? String(standardized.dropFirst(top.count + 1)) : path
    })
    paths = paths.filter { wanted.contains($0) }
}

var problems = 0
var changed = 0
for path in paths.sorted() {
    guard let treatment = LicenseHeaders.treatment(for: path) else {
        print("\(path): no rule classifies this file — add one to LicenseHeaders.rules")
        problems += 1
        continue
    }
    guard case .header(let style) = treatment else { continue }
    let url = URL(fileURLWithPath: "\(top)/\(path)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("\(path): not readable as UTF-8")
        problems += 1
        continue
    }
    switch command {
    case "fix":
        if let updated = LicenseHeaders.fixed(text, style: style, year: year, currentYear: max(year, currentYear)) {
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
                print("added: \(path)")
                changed += 1
            } catch {
                print("\(path): \(error.localizedDescription)")
                problems += 1
            }
        } else if case .malformed(let reason)? = LicenseHeaders.check(text, style: style, currentYear: max(year, currentYear)) {
            print("\(path): malformed header, not changed — \(reason)")
            problems += 1
        }
    default:
        switch LicenseHeaders.check(text, style: style, currentYear: currentYear) {
        case nil: break
        case .missing:
            print("\(path): missing license header")
            problems += 1
        case .malformed(let reason):
            print("\(path): malformed license header — \(reason)")
            problems += 1
        }
    }
}

if command == "fix" { print("\(changed) file(s) given a header") }
if problems > 0 {
    print("\(problems) problem(s); docs/LICENSING.md has the rules")
    exit(1)
}
if command == "check" { print("\(paths.count) files checked; every header is in place") }
