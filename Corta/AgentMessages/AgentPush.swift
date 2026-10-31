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

import Darwin
import Foundation

nonisolated enum AgentPush {
    /// One NDJSON line for Claude's per-session socket. No token is attached.
    static func claudeLine(envelope: String, messageID: String) -> String {
        let object: [String: Any] = [
            "type": "user", "message": ["role": "user", "content": envelope],
            "priority": "next", "msgV": 1, "msg_id": messageID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func codexArguments(executable: String, thread: String, message: String) -> [String]? {
        guard !executable.isEmpty, !thread.isEmpty, !thread.contains(" "), !message.contains("\0"),
              thread.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return [executable, "queue", "--thread", thread, "--message", message]
    }

    /// Claude's inbox lives under its private socket directory, never an arbitrary path.
    static func acceptedSocket(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("..") && path.utf8.count < 104
            && (path.contains("cc-socks") || path.contains("claude"))
    }

    static func writeClaude(socket path: String, envelope: String) -> Bool {
        var info = stat()
        guard acceptedSocket(path), lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFSOCK else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var directory = stat()
        guard lstat(parent, &directory) == 0, directory.st_uid == getuid(),
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o077 == 0 else { return false }
        guard var address = SSHAskpass.socketAddress(path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var on: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let line = claudeLine(envelope: envelope, messageID: "cc-msg-corta-" + UUID().uuidString)
        return SSHAskpass.writeLine(Data(line.dropLast().utf8), to: descriptor)
    }

    static func run(_ arguments: [String], timeout: TimeInterval) -> Bool {
        guard let executable = arguments.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = AgentPushOutput(limit: 64 * 1024)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if !output.accept(data) { process.terminate() }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
        do { try process.run() } catch { return false }
        let deadline = SuspendingClock.now.advanced(by: .seconds(timeout))
        while process.isRunning, SuspendingClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = SuspendingClock.now.advanced(by: .milliseconds(200))
            while process.isRunning, SuspendingClock.now < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return false
        }
        return process.terminationStatus == 0 && !output.exceeded
    }
}

/// Only the byte count crosses the pipe callback; every access holds the lock.
nonisolated private final class AgentPushOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return count > limit }
    func accept(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += data.count
        return count <= limit
    }
}
