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

extension AgentHub {
    nonisolated static var identityRefusal: AgentReply {
        AgentReply(ok: false, text: "refused(identity)", delivery: "refused")
    }

    /// Each SSH connection forwards a distinct private endpoint. Authentication does
    /// not depend on the PID of an SSH ControlMaster owned by an earlier connection.
    func remoteEndpoint(token: String, member: UUID, tmux: String) -> String? {
        guard caller(token: token) == member, let socketPath else { return nil }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        let path = directory + "/r-" + token.prefix(16) + ".sock"
        guard let endpoint = AgentSocketServer(directory: directory, path: path, handler: { [weak self] request, _ in
            guard let self else { return Self.identityRefusal }
            return await self.receiveRemote(request, token: token, member: member, tmux: tmux)
        }) else { return nil }
        remoteSessionNames[token] = tmux
        remoteEndpoints[token] = endpoint
        return path
    }

    func receiveRemote(_ request: AgentRequest, token: String, member: UUID, tmux: String) async -> AgentReply {
        guard socketPath != nil, request.token == token, request.tmux == tmux,
              remoteEndpoints[token] != nil, caller(token: token) == member else { return Self.identityRefusal }
        markRemoteReady(member)
        bus.forwardsDown.remove(member)
        return handle(request, caller: member)
    }

    func pruneRemoteEndpoints() {
        for (token, endpoint) in remoteEndpoints where remoteTokens[token] == nil {
            endpoint.stop()
            remoteEndpoints[token] = nil
        }
        remoteSessionNames = remoteSessionNames.filter { remoteTokens[$0.key] != nil }
    }
}
