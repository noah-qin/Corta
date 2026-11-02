// Copyright 2026 Noah Qin
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// Presentation-only interpreter entry point. Never reads a command from
/// terminal output, executes it, or retains the rest of the command line.
enum ProcessEntryPoint {
    static func isInterpreter(_ process: String) -> Bool {
        let name = process.lowercased()
        if ["node", "nodejs", "bun", "deno"].contains(name) { return true }
        guard name.hasPrefix("python") else { return false }
        let version = name.dropFirst(6)
        return version.isEmpty || (version.first?.isNumber == true
            && version.allSatisfy { $0.isNumber || $0 == "." })
    }

    static func read(pid: pid_t, process: String) -> String? {
        guard isInterpreter(process) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 131_072 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return resolve(process: process, arguments: argumentPrefix(Array(bytes.prefix(size))))
    }

    /// KERN_PROCARGS2: argc, executable path, padding, then NUL-delimited argv.
    /// Stop after sixteen arguments; environment variables are never parsed.
    static func argumentPrefix(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= 4 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096,
              let pathEnd = bytes[4...].firstIndex(of: 0) else { return [] }
        var cursor = pathEnd + 1
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<min(Int(argc), 16) {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  end - cursor <= 4096,
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return [] }
            arguments.append(value)
            cursor = end + 1
        }
        return arguments
    }

    static func resolve(process: String, arguments: [String]) -> String? {
        guard isInterpreter(process), !arguments.isEmpty else { return nil }
        var index = 1
        while index < arguments.count {
            let value = arguments[index]
            guard value != "-" else { return nil }
            if value == "--" { return arguments.dropFirst(index + 1).first }
            if process.lowercased().hasPrefix("python") {
                if value == "-c" { return nil }
                if value == "-m" { return arguments.dropFirst(index + 1).first }
                if ["-W", "-X"].contains(value) { index += 2; continue }
                if ["-u", "-B", "-E", "-I", "-s", "-S", "-O", "-OO", "-q"].contains(value) {
                    index += 1; continue
                }
            } else {
                if ["-e", "--eval", "-p", "--print"].contains(value)
                    || value.hasPrefix("--eval=") || value.hasPrefix("--print=") { return nil }
                if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(value) {
                    index += 2; continue
                }
                if ["--no-warnings", "--no-deprecation", "--enable-source-maps", "--inspect",
                    "--inspect-brk", "--experimental-strip-types"].contains(value)
                    || ["--require=", "--import=", "--loader=", "--inspect="].contains(where: value.hasPrefix) {
                    index += 1; continue
                }
                if ["bun", "deno"].contains(process.lowercased()), value == "run" {
                    index += 1; continue
                }
            }
            guard !value.hasPrefix("-") else { return nil }
            return value
        }
        return nil
    }
}
