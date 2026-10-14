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

/// What every child Corta spawns starts with (`SECURITY.md` §4.3): every
/// signal at its default action and none blocked, whatever this process
/// ignores or masks. Callers still choose the spawn flags; these two need
/// `POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK` among them.
public func resetSignals(of attributes: inout posix_spawnattr_t?) {
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
}

/// `strings` as a NULL-terminated `char *[]` for `posix_spawn`'s argv or
/// envp, valid for the duration of `body`.
package func withCStringArray<Result>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
