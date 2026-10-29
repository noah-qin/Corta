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

extension PTY {
    /// Bounded kernel metadata only. Call off main; no files are opened or read.
    public var localConversation: LocalConversation? {
        guard exitStatus == nil, let group = foregroundProcessGroup,
              let name = Self.processName(of: group),
              LocalConversation.Kind(processName: name) != nil else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let capacity = Int32(descriptors.count * stride)
        let bytes = proc_pidinfo(group, PROC_PIDLISTFDS, 0, &descriptors, capacity)
        // A full buffer may have omitted another candidate: don't guess.
        guard bytes > 0, bytes < capacity else { return nil }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(group, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            paths.append(path)
        }
        guard exitStatus == nil, foregroundProcessGroup == group,
              Self.processName(of: group) == name else { return nil }
        return LocalConversation.openedFiles(processName: name, paths: paths)
    }
}
