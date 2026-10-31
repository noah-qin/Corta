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

/// Owns descriptors on its own queue; no blocking I/O runs on the main actor.
nonisolated final class AgentSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentRequest, pid_t) async -> AgentReply
    private let source: DispatchSourceRead
    private let slots = DispatchSemaphore(value: 16)
    private let clients = DispatchQueue(label: "dev.noahqin.Corta.agent.clients", attributes: .concurrent)
    private let handler: Handler
    private let path: String

    init?(directory: String, path: String, handler: @escaping Handler) {
        self.handler = handler
        self.path = path
        mkdir(directory, 0o700)
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFDIR else { return nil }
        chmod(directory, 0o700)
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard var address = SSHAskpass.socketAddress(path) else { close(descriptor); return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            unlink(path)
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: clients)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in self?.accept(descriptor) }
        source.resume()
    }

    func stop() { unlink(path); source.cancel() }
    deinit { source.cancel() }

    private func accept(_ listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        guard slots.wait(timeout: .now()) == .success else { close(client); return }
        let slots = self.slots
        let handler = self.handler
        clients.async {
            var seconds = timeval(tv_sec: 5, tv_usec: 0)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
            guard let line = SSHAskpass.readLine(from: client, limit: AgentEnvelope.bodyLimit * 6 + 8192),
                  let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
                close(client)
                slots.signal()
                return
            }
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            _ = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
            let peer = pid
            Task {
                let reply = await handler(request, peer)
                if let data = try? JSONEncoder().encode(reply) { _ = SSHAskpass.writeLine(data, to: client) }
                close(client)
                slots.signal()
            }
        }
    }
}
