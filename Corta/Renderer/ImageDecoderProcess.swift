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
import Metal

/// Kitty PNG decoding out of process: `corta-image-decoder`, embedded beside
/// `corta-exec`, decodes under the `pure-computation` sandbox (its doc
/// comment has why), and this side spawns it, feeds it the PNG, and holds
/// what comes back to the same caps the stream was held to.
///
/// `posix_spawn` and its own `waitpid`, not `Process`: `Process` reaps on a
/// queue of its own, and killing a decoder that ran past `timeout` by a pid
/// someone else may already have reaped could signal a stranger
/// (`SECURITY.md` S08). Every descriptor is close-on-exec before the spawn,
/// and the child gets only stdin/stdout/stderr plus the pixel descriptor, an empty environment and its own
/// session.
///
/// Blocking, for the decode scheduler's queue — never the main thread.
nonisolated enum ImageDecoderProcess {
    static let helperName = "corta-image-decoder"

    /// A PNG under the caps decodes in well under a second; a decoder still
    /// running after this is killed and the image is not drawn.
    static let timeout: Duration = .seconds(10)

    /// Owns the anonymous mapping until its Metal buffer's final owner releases it.
    /// The decode worker writes it before publication; afterwards pixels are immutable.
    // The decode worker is the sole writer before publication; Metal only
    // samples immutable pixels and may release ownership on its completion thread.
    final class SharedPixels: @unchecked Sendable {
        private static let mappingBudget = GlobalTextureBudget(
            limit: KittyGraphics.maximumGlobalTextureBytes)
        let descriptor: Int32
        let address: UnsafeMutableRawPointer
        let length: Int
        let bytesPerRow: Int
        init?(width: Int, height: Int, alignment: Int) {
            guard width > 0, height > 0, width <= KittyGraphics.maximumImageDimension,
                height <= KittyGraphics.maximumImageDimension,
                width <= KittyGraphics.maximumImagePixels / height
            else { return nil }
            let alignment = max(4, alignment)
            bytesPerRow = ((width * 4 + alignment - 1) / alignment) * alignment
            let page = Int(getpagesize())
            length = ((bytesPerRow * height + page - 1) / page) * page
            guard length <= KittyGraphics.maximumImageBytes, Self.mappingBudget.tryReserve(length)
            else {
                return nil
            }
            let allocationLength = length
            var allocated = false
            defer { if !allocated { Self.mappingBudget.release(allocationLength) } }
            let name = "/corta-" + UUID().uuidString.prefix(20)
            let opened = name.withCString {
                sharedMemoryOpen($0, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
            }
            guard opened >= 0 else { return nil }
            shm_unlink(name)
            // Spawn actions must have distinct source/destination descriptors:
            // dup2(3, 3) does not reliably clear CLOEXEC under CLOEXEC_DEFAULT.
            let fd = opened < 4 ? fcntl(opened, F_DUPFD_CLOEXEC, 4) : opened
            if opened < 4 { close(opened) }
            guard fd >= 4 else { return nil }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            guard ftruncate(fd, off_t(length)) == 0,
                let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                mapping != MAP_FAILED
            else {
                close(fd)
                return nil
            }
            descriptor = fd
            address = mapping
            allocated = true
        }
        deinit {
            munmap(address, length)
            close(descriptor)
            Self.mappingBudget.release(length)
        }
        func texture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
            guard
                let buffer = device.makeBuffer(
                    bytesNoCopy: address, length: length,
                    options: .storageModeShared, deallocator: { [self] _, _ in _ = self })
            else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        }
        func packedBytes(width: Int, height: Int) -> [UInt8] {
            var result = [UInt8]()
            result.reserveCapacity(width * height * 4)
            for row in 0..<height {
                result.append(
                    contentsOf: UnsafeBufferPointer(
                        start: address.advanced(by: row * bytesPerRow).assumingMemoryBound(
                            to: UInt8.self),
                        count: width * 4))
            }
            return result
        }
    }

    struct Decoded {
        var width: Int
        var height: Int
        var pixels: SharedPixels
        // Inspection only; the texture path never asks for a packed CPU copy.
        var bgra: [UInt8] { pixels.packedBytes(width: width, height: height) }
    }

    static func pngDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 24,
            bytes.prefix(16).elementsEqual([
                0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10,
                0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
            ])
        else { return nil }
        func word(_ at: Int) -> Int {
            Int(
                UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
                    | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]))
        }
        let width = word(16)
        let height = word(20)
        guard width > 0, height > 0, width <= KittyGraphics.maximumImageDimension,
            height <= KittyGraphics.maximumImageDimension,
            width <= KittyGraphics.maximumImagePixels / height
        else { return nil }
        return (width, height)
    }

    /// The helper in the running app's `Contents/MacOS`.
    static var bundledHelper: String? {
        Bundle.main.url(forAuxiliaryExecutable: helperName)?.path
    }

    /// `nil` for anything but a decoded PNG under the caps: no helper, a
    /// spawn that failed, a nonzero exit, a timeout, or output whose size
    /// disagrees with its own header.
    static func decodePNG(
        _ bytes: [UInt8], helper: String? = ImageDecoderProcess.bundledHelper,
        timeout: Duration = ImageDecoderProcess.timeout, alignment: Int = 256
    ) -> Decoded? {
        guard let helper, bytes.count <= KittyGraphics.maximumImageBytes,
            let dimensions = pngDimensions(bytes),
            let pixels = SharedPixels(
                width: dimensions.width, height: dimensions.height, alignment: alignment)
        else {
            return nil
        }
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { return nil }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0])
            close(toChild[1])
            return nil
        }
        guard normalizeDescriptors(&toChild), normalizeDescriptors(&fromChild) else {
            for fd in toChild + fromChild { close(fd) }
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pixels.descriptor, 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv0 = strdup(helper)
        defer { free(argv0) }
        let argv: [UnsafeMutablePointer<CChar>?] = [argv0, nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, helper, &actions, &attributes, argv, envp)
        close(toChild[0])
        close(fromChild[1])
        guard spawned == 0 else {
            close(toChild[1])
            close(fromChild[0])
            return nil
        }

        var input = [UInt8]()
        for word in [dimensions.width, dimensions.height, pixels.bytesPerRow] {
            let value = UInt32(word)
            input += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        input += bytes
        let deadline = ContinuousClock.now + timeout
        let output = exchange(
            input: input, writeTo: toChild[1], readFrom: fromChild[0],
            limit: 8, deadline: deadline)
        if output == nil { kill(pid, SIGKILL) }
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0, errno != EINTR { return nil }
            if ContinuousClock.now >= deadline { kill(pid, SIGKILL) }
            usleep(1000)
        }
        guard let output, status == 0 else { return nil }
        guard let reported = parse(output), reported.width == dimensions.width,
            reported.height == dimensions.height
        else { return nil }
        return Decoded(width: reported.width, height: reported.height, pixels: pixels)
    }

    /// Keep all spawn sources away from stdin/stdout/stderr and the pixel destination.
    private static func normalizeDescriptors(_ descriptors: inout [Int32]) -> Bool {
        for index in descriptors.indices {
            let source = descriptors[index]
            if source < 4 {
                let copy = fcntl(source, F_DUPFD_CLOEXEC, 4)
                guard copy >= 4 else { return false }
                close(source)
                descriptors[index] = copy
            } else {
                _ = fcntl(source, F_SETFD, FD_CLOEXEC)
            }
        }
        return true
    }

    /// Writes `input` and reads to end of file, both against `deadline`, with
    /// neither side able to block the other. Closes both descriptors. `nil`
    /// on a timeout, an error, or more output than `limit`.
    private static func exchange(
        input: [UInt8], writeTo writer: Int32, readFrom reader: Int32, limit: Int,
        deadline: ContinuousClock.Instant
    ) -> [UInt8]? {
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        var writerOpen = true
        defer {
            if writerOpen { close(writer) }
            close(reader)
        }
        var written = 0
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            let milliseconds = Int32(
                clamping: remaining.components.seconds * 1000
                    + remaining.components.attoseconds / 1_000_000_000_000_000)
            var descriptors = [pollfd(fd: reader, events: Int16(POLLIN), revents: 0)]
            if writerOpen { descriptors.append(pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), max(milliseconds, 1))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if writerOpen, descriptors.count > 1, descriptors[1].revents != 0 {
                let count = input.withUnsafeBytes { buffer in
                    Darwin.write(writer, buffer.baseAddress! + written, buffer.count - written)
                }
                if count > 0 {
                    written += count
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    // The decoder stopped reading (it refused the input and
                    // exited); its exit status is the verdict.
                    written = input.count
                }
                if written == input.count {
                    close(writer)
                    writerOpen = false
                }
            }
            if descriptors[0].revents != 0 {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }
                if count == 0 { return output }
                if count > 0 {
                    guard output.count + count <= limit else { return nil }
                    output.append(contentsOf: chunk[0..<count])
                } else if errno != EAGAIN, errno != EINTR {
                    return nil
                }
            }
        }
    }

    /// Exactly the bounded success header, never pixel data on stdout.
    static func parse(_ output: [UInt8]) -> (width: Int, height: Int)? {
        guard output.count == 8 else { return nil }
        func word(_ at: Int) -> Int {
            Int(
                UInt32(output[at]) | UInt32(output[at + 1]) << 8 | UInt32(output[at + 2]) << 16
                    | UInt32(output[at + 3]) << 24)
        }
        let width = word(0)
        let height = word(4)
        guard width > 0, height > 0, width <= KittyGraphics.maximumImageDimension,
            height <= KittyGraphics.maximumImageDimension,
            width <= KittyGraphics.maximumImagePixels / height
        else { return nil }
        return (width, height)
    }
}

@_silgen_name("corta_shared_memory_open")
nonisolated private func sharedMemoryOpen(
    _ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t
) -> Int32
