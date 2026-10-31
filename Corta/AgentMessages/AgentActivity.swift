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

import CortaTerminal
import Darwin
import Foundation

/// Kernel counters sampled only by the metadata monitor, never by the frame loop.
nonisolated struct AgentActivity: Sendable {
    var group: pid_t
    var start: UInt64
    var cpu: UInt64
    var processes: Set<pid_t>
    var kind: String?
    var toolActive: Bool
    var at: TimeInterval

    func idle(after previous: AgentActivity?) -> Bool {
        guard !toolActive, let previous, previous.group == group, previous.start == start,
              at - previous.at >= 0.5, cpu >= previous.cpu,
              processes == previous.processes else { return false }
        return cpu - previous.cpu < 10_000_000
    }

    static func read(_ terminal: TerminalSession, configured: String) -> AgentActivity? {
        guard terminal.pty.exitStatus == nil, let group = terminal.pty.foregroundProcessGroup,
              group != terminal.pty.processIdentifier else { return nil }
        var ids = [pid_t](repeating: 0, count: 256)
        let count = proc_listpgrppids(group, &ids, Int32(ids.count * MemoryLayout<pid_t>.size))
        guard count > 0, count < ids.count else { return nil }
        var cpu: UInt64 = 0
        var processes = Set<pid_t>()
        var kind: String?
        var toolActive = false
        var start: UInt64 = 0
        for pid in ids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let invoked = ConversationProcess.invocationName(pid) ?? name
            if AgentProcessNames.matches(invoked, configured: configured) { kind = invoked }
            if AgentProcessNames.matches(name, configured: configured) { kind = name }
            if pid != group, !AgentProcessNames.matches(name, configured: configured),
               !AgentProcessNames.matches(invoked, configured: configured),
               !["node", "bun", "python", "python3", "deno"].contains(name) { toolActive = true }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { return nil }
            cpu &+= usage.ri_user_time &+ usage.ri_system_time
            processes.insert(pid)
            start &+= info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        }
        return AgentActivity(group: group, start: start, cpu: cpu, processes: processes, kind: kind,
            toolActive: toolActive,
                             at: ProcessInfo.processInfo.systemUptime)
    }
}
