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
import Synchronization

/// `PTY.foregroundProgram`'s last reading, by the group's pids.
struct ForegroundProgramCache {
    var pids: [pid_t]
    var time: UInt64
    var program: ForegroundProgram?
    var entries: [pid_t: ForegroundProgram.Member]
}

extension PTY {
    /// Every member of the foreground group, leader first, at most sixteen:
    /// an agent run through a wrapper (`caffeinate`, `npx`, `op run`) is a
    /// member, not the leader. Nil when the group cannot be read.
    ///
    /// Names are read again for every wait, since `exec` keeps a pid and
    /// changes the program; only an interpreter's script, the costly read,
    /// is kept for the same pid and name. Within 100 ms of the last read of
    /// the same members, that read stands: a stream that begins a wait in
    /// every slice costs two syscalls a slice. An `exec` in that window is
    /// judged as the program before it.
    public var foregroundProgram: ForegroundProgram? {
        guard let group = foregroundProcessGroup else { return nil }
        let pids = [group] + Self.members(ofGroup: group).filter { $0 != group }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cached = foregroundProgramCache.withLock { $0 }
        if let cached, cached.pids == pids, now &- cached.time < 100_000_000 { return cached.program }
        var members: [ForegroundProgram.Member] = []
        var entries: [pid_t: ForegroundProgram.Member] = [:]
        for pid in pids where members.count < 16 {
            guard let name = Self.processName(of: pid) else { continue }
            let known = cached?.entries[pid].flatMap { $0.name == name ? $0 : nil }
            let member = known ?? .init(name: name, entryPoint: ProcessEntryPoint.read(pid: pid, process: name))
            members.append(member)
            entries[pid] = member
        }
        let program = members.isEmpty ? nil : ForegroundProgram(members: members)
        foregroundProgramCache.withLock { $0 = ForegroundProgramCache(pids: pids, time: now, program: program, entries: entries) }
        return program
    }

    /// The group's live members, at most 64. `proc_listpgrppids` takes the
    /// buffer's size in bytes and returns a count of pids: libproc divides.
    static func members(ofGroup group: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }
}
