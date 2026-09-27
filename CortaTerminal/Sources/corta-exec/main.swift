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

/// The second half of `Spawn.child`: a fresh, single-threaded image, so
/// ordinary Swift is safe here. It arrives a session leader with the pty on
/// fds 0/1/2; it adds what `posix_spawn` cannot express — `TIOCSCTTY` —
/// then `execve`s the shell.
///
/// argv: `[self, errorPipeWriteFD, workingDirectory-or-empty, executable,
/// arg0, …]`; `executable` doubles as the target's `argv[0]`.
let arguments = CommandLine.arguments

func fail() -> Never {
    if let pipeFD = Int32(arguments[1]) {
        var code = errno
        withUnsafeBytes(of: &code) { buffer in
            _ = Darwin.write(pipeFD, buffer.baseAddress, buffer.count)
        }
    }
    _exit(127)
}

guard arguments.count >= 4 else { _exit(127) }

// Inherited across our own exec without its `FD_CLOEXEC` flag. Unset, the
// shell holds the error pipe open, the parent's read never sees EOF, and
// every spawn of a long-lived program hangs.
if let pipeFD = Int32(arguments[1]) {
    _ = fcntl(pipeFD, F_SETFD, FD_CLOEXEC)
}

guard ioctl(0, TIOCSCTTY, 0) == 0 else { fail() }

let workingDirectory = arguments[2]
if !workingDirectory.isEmpty, chdir(workingDirectory) != 0 { fail() }

let targetArguments = Array(arguments[3...])
var targetArgv: [UnsafeMutablePointer<CChar>?] = targetArguments.map { strdup($0) }
targetArgv.append(nil)

execve(targetArguments[0], &targetArgv, environ)
fail()
