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
import Security
import Synchronization

/// Corta's executable started by ssh as `SSH_ASKPASS`: carries the question
/// to the app and prints the answer. Runs before `NSApplication` exists, so
/// it never shows in the Dock; anything but an answer exits non-zero, which
/// ssh treats as the question cancelled.
nonisolated enum SSHAskpassClient {
    /// The exit status when this process is ssh's askpass, nil otherwise.
    static func runIfInvoked(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard let path = environment[SSHAskpass.socketVariable],
            let token = environment[SSHAskpass.tokenVariable]
        else { return nil }
        let request = SSHAskpass.Request(
            token: token, kind: SSHAskpass.Kind(promptVariable: environment["SSH_ASKPASS_PROMPT"]),
            prompt: arguments.dropFirst().first ?? "")
        guard let reply = exchange(request, socketPath: path), let answer = reply.answer else {
            return 1
        }
        if request.kind != .notify {
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        }
        return 0
    }

    /// One request, one reply. A notice is never answered: the read waits
    /// until ssh, done with it, ends this process.
    static func exchange(_ request: SSHAskpass.Request, socketPath: String) -> SSHAskpass.Reply? {
        guard var address = SSHAskpass.socketAddress(socketPath),
            let encoded = try? JSONEncoder().encode(request)
        else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, SSHAskpass.writeLine(encoded, to: descriptor),
            let line = SSHAskpass.readLine(from: descriptor, limit: SSHAskpass.requestLimit)
        else { return nil }
        return try? JSONDecoder().decode(SSHAskpass.Reply.self, from: line)
    }
}
