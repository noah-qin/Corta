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

/// Launches a child on a pty replica by `posix_spawn`ing `corta-exec`, which
/// adds `TIOCSCTTY` (`posix_spawn` cannot express it) and `execve`s the shell.
///
/// Not `fork()`: in a multithreaded Cocoa process a forked child is only as
/// safe as the locks other threads hold at that instant, and it was killed
/// ~8% of the time even fully serialized (`DESIGN.md` §7.2).
enum Spawn {
    /// - Parameters:
    ///   - parentReplica: the caller's reference, used for the initial size;
    ///     closed here the instant `corta-exec` has its own.
    ///   - workingDirectory: absolute, or `nil` to inherit ours.
    static func child(
        executable: String,
        arguments: [String],
        environment: [String: String],
        replicaPath: String,
        parentReplica: Int32,
        workingDirectory: String?
    ) throws(PTYError) -> pid_t {
        // Early-throw paths; the real close site disarms it.
        var parentReplicaClosed = false
        defer { if !parentReplicaClosed { close(parentReplica) } }

        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        guard let helperPath = locateHelperExecutable() else {
            throw .spawnFailed(code: ENOENT)
        }

        // `posix_spawn` only reports launching `corta-exec`; this reports its
        // `execve` of the target.
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else { throw .spawnFailed(code: errno) }
        let readEnd = errorPipe[0]
        let writeEnd = errorPipe[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        // Closed by `execve` succeeding — the parent's "it worked".
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, replicaPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addinherit_np(&fileActions, writeEnd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        // Default signal actions, nothing blocked (`SECURITY.md` §4.3).
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        // Everything else this process has open stays out of the child.

        var childArguments = [helperPath, String(writeEnd), workingDirectory ?? "", executable]
        childArguments.append(contentsOf: arguments)
        let environmentLines = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var pid: pid_t = 0
        let spawnResult = withCStringArray(childArguments) { argv in
            withCStringArray(environmentLines) { envp in
                posix_spawn(&pid, helperPath, &fileActions, &attributes, argv, envp)
            }
        }
        guard spawnResult == 0 else {
            close(readEnd)
            close(writeEnd)
            throw .spawnFailed(code: spawnResult)
        }

        // `corta-exec` holds its own reference once `posix_spawn` returns, so
        // close now: waiting could make this the *last* close, and on Darwin a
        // last close by the primary's holder discards unread child output. Never a
        // gap with no reference either — that reset the size to 0×0.
        close(parentReplica)
        parentReplicaClosed = true

        close(writeEnd)
        defer { close(readEnd) }
        // Bounded: the UI calls this synchronously.
        let status = Self.readHelperStatus(
            from: readEnd,
            deadline: ContinuousClock.now + Self.helperHandshakeTimeout
        )
        switch status {
        case .execSucceeded:
            return pid
        case .execFailed(let code):
            Self.reapFailedChild(pid)
            throw .spawnFailed(code: code)
        case .truncated:
            Self.reapFailedChild(pid)
            throw .spawnFailed(code: EIO)
        case .timedOut:
            Self.reapFailedChild(pid)
            throw .spawnFailed(code: ETIMEDOUT)
        case .readFailed(let code):
            Self.reapFailedChild(pid)
            throw .spawnFailed(code: code)
        }
    }

    /// Generous — a false positive kills a healthy shell.
    static let helperHandshakeTimeout: Duration = .seconds(10)

    /// The helper writes its `errno` (one native-order `Int32`) on failure; on
    /// success the write end closes with no bytes.
    enum HelperStatus: Equatable {
        case execSucceeded
        case execFailed(code: Int32)
        case truncated
        case timedOut
        case readFailed(code: Int32)
    }

    static func readHelperStatus(
        from readEnd: Int32, deadline: ContinuousClock.Instant
    ) -> HelperStatus {
        var reported: Int32 = 0
        let total = MemoryLayout<Int32>.size
        var filled = 0
        while filled < total {
            let now = ContinuousClock.now
            guard now < deadline else { return .timedOut }
            let remaining = now.duration(to: deadline)
            let milliseconds = Int32(
                clamping: remaining.components.seconds * 1000
                    + remaining.components.attoseconds / 1_000_000_000_000_000)

            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, max(milliseconds, 1))
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                return .readFailed(code: errno)
            }

            let count = withUnsafeMutableBytes(of: &reported) { buffer in
                Darwin.read(readEnd, buffer.baseAddress! + filled, total - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .readFailed(code: errno)
            }
            if count == 0 {
                return filled == 0 ? .execSucceeded : .truncated
            }
            filled += count
        }
        return .execFailed(code: reported)
    }

    /// Kill if alive, reap either way: no zombie on a failure path.
    private static func reapFailedChild(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// Beside the image this module was loaded from (`dladdr`), not the
    /// process's executable: under `swift test` the runner `dlopen`s the
    /// `.xctest` bundle, so the process path points outside the package.
    private static func locateHelperExecutable() -> String? {
        var info = Dl_info()
        let addressInThisModule = unsafeBitCast(
            addressAnchor, to: UnsafeMutableRawPointer.self)
        guard dladdr(addressInThisModule, &info) != 0, let fname = info.dli_fname else {
            return nil
        }
        var path = String(cString: fname)
        if let resolved = realpath(path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }

        var directory = path
        for _ in 0..<6 {
            guard let slash = directory.lastIndex(of: "/"), slash != directory.startIndex else {
                break
            }
            directory = String(directory[directory.startIndex..<slash])
            let candidate = directory + "/corta-exec"
            if access(candidate, X_OK) == 0 { return candidate }
            // In the app, the helper is in Contents/MacOS while this image is a
            // framework under Contents/Frameworks — never an ancestor, so check it
            // when the walk passes Contents. The only layout app-hosted tests spawn in.
            if directory.hasSuffix("/Contents") {
                let insideBundle = directory + "/MacOS/corta-exec"
                if access(insideBundle, X_OK) == 0 { return insideBundle }
            }
        }
        return nil
    }
}

/// A C function pointer, not a Swift closure (which can be a fat pointer):
/// `dladdr` needs one address inside this module.
private let addressAnchor: @convention(c) () -> Void = {}

/// A null-terminated `char *[]`, valid for `body`.
private func withCStringArray<Result>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
