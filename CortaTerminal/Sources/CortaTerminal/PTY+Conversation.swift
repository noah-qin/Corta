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
import Synchronization

extension PTY {
    /// Bounded background sampling of the whole foreground group, including npm wrappers.
    public var conversationSample: ConversationSample? {
        guard exitStatus == nil, let group = foregroundProcessGroup else { return nil }
        var members = [pid_t](repeating: 0, count: 256)
        let count = proc_listpgrppids(group, &members, Int32(members.count * MemoryLayout<pid_t>.size))
        guard count > 0, count < members.count else { return nil }
        let identities = members.prefix(Int(count)).compactMap(ConversationProcess.read)
        if ConversationSample.isMixed(identities) {
            guard exitStatus == nil, foregroundProcessGroup == group,
                  identities.allSatisfy({ ConversationProcess.read($0.pid) == $0 }) else { return nil }
            return .mixedProcesses
        }
        guard let (kind, agents) = ConversationObservation.recognized(identities) else { return nil }
        let result: ConversationObservation
        if kind == .claude {
            // Multiple Claude members cannot be attributed to one conversation safely.
            guard agents.count == 1, let agent = agents.first else {
                return .observed(ConversationObservation(kind: kind, processes: agents, reason: .processMismatch))
            }
            result = conversationCache.withLock { cache in
                guard let home = ConversationProcess.homeDirectory(agent.pid) else {
                    return ConversationObservation(kind: .claude, processes: agents, reason: .recordUnreadable)
                }
                let directory = home.appendingPathComponent(".claude/sessions", isDirectory: true)
                return cache.read(process: agent, directory: directory) {
                    ConversationProcess.read(agent.pid) == agent
                }
            }
        } else {
            let lists = members.prefix(Int(count)).map { Self.conversationFiles(of: $0) }
            let files = lists.allSatisfy({ $0 != nil }) ? lists.compactMap { $0 }.flatMap { $0 } : nil
            result = ConversationObservation.codex(processes: agents, files: files)
        }
        guard exitStatus == nil, foregroundProcessGroup == group,
              agents.allSatisfy({ ConversationProcess.read($0.pid) == $0 }) else { return nil }
        return .observed(result)
    }

    public var conversationObservation: ConversationObservation? {
        guard case .observed(let observation) = conversationSample else { return nil }
        return observation
    }

    public var localConversation: LocalConversation? { conversationObservation?.conversation }

    private static func conversationFiles(of pid: pid_t) -> [LocalConversation.OpenedFile]? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let capacity = Int32(descriptors.count * stride)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, capacity)
        // A full buffer may have omitted another candidate: don't guess.
        guard bytes > 0, bytes < capacity else { return nil }
        var files: [LocalConversation.OpenedFile] = []
        for descriptor in descriptors.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let stat = info.pvip.vip_vi.vi_stat
            files.append(LocalConversation.OpenedFile(
                path: path,
                modified: Self.fileTime(seconds: stat.vst_mtime, nanoseconds: stat.vst_mtimensec),
                created: Self.fileTime(seconds: stat.vst_birthtime, nanoseconds: stat.vst_birthtimensec)))
        }
        return files
    }

    /// Epoch is not a time the kernel measured for this descriptor.
    private static func fileTime(seconds: Int64, nanoseconds: Int64) -> LocalConversation.FileTime? {
        guard seconds != 0 || nanoseconds != 0 else { return nil }
        return LocalConversation.FileTime(seconds: seconds, nanoseconds: nanoseconds)
    }
}
