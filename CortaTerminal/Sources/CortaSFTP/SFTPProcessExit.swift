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

/// How the channel's `ssh` (or test `sftp-server`) ended — the SFTP side's
/// own spelling of the core's `ChildExit`, since the two modules share no
/// code.
public enum SFTPProcessExit: Equatable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32)

    /// Decodes a `waitpid` status word.
    ///
    /// The `W*` macros in `<sys/wait.h>` are function-like macros and are
    /// therefore not imported into Swift; the arithmetic is reproduced here.
    init(waitpidStatus status: Int32) {
        let termination = status & 0o177
        if termination == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else {
            self = .signalled(signal: termination)
        }
    }
}
