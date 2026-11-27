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

import CortaPOSIX
import CortaTerminal
import Darwin
import Foundation

private struct RecordingError: Error, CustomStringConvertible {
    let description: String
}

private func systemError(_ operation: String) -> RecordingError {
    RecordingError(description: "\(operation): \(String(cString: strerror(errno)))")
}

private func terminalSize() throws -> winsize {
    var size = winsize()
    guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { throw systemError("read terminal size") }
    guard size.ws_row > 0, size.ws_col > 0 else {
        throw RecordingError(description: "the outer terminal has no rows or columns")
    }
    return size
}

private extension TerminalSize {
    init(_ dimensions: winsize) {
        self.init(
            rows: dimensions.ws_row, columns: dimensions.ws_col,
            pixelWidth: dimensions.ws_xpixel, pixelHeight: dimensions.ws_ypixel)
    }
}

private func setMode(_ mode: inout termios) throws {
    while tcsetattr(STDIN_FILENO, TCSANOW, &mode) != 0 {
        if errno != EINTR { throw systemError("set terminal mode") }
    }
}

private func writeToTerminal(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
        let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
        if count > 0 {
            offset += count
        } else if count == 0 || errno != EINTR {
            throw systemError("write to outer terminal")
        }
    }
}

/// Keep printable text readable and preserve every byte even when a read
/// splits UTF-8. A resize flushes an incomplete scalar before its directive.
private struct RecordingWriter {
    let file: FileHandle
    private var pending: [UInt8] = []

    init(file: FileHandle) { self.file = file }

    mutating func flush() throws {
        try write(UnsafeRawBufferPointer(start: nil, count: 0), flush: true)
    }

    mutating func write(_ bytes: UnsafeRawBufferPointer, flush: Bool = false) throws {
        let input = pending + Array(bytes)
        pending.removeAll(keepingCapacity: true)
        var line = ""
        var index = 0
        while index < input.count {
            let byte = input[index]
            switch byte {
            case 0x1B: line += #"\e"#
            case 0x07: line += #"\a"#
            case 0x08: line += #"\b"#
            case 0x09: line += #"\t"#
            case 0x0A: line += "\\n\n"
            case 0x0D: line += #"\r"#
            case 0x5C: line += #"\\"#
            case 0x23 where line.isEmpty, 0x40 where line.isEmpty:
                line += String(format: "\\x%02x", byte)
            case 0x20...0x7E:
                line.unicodeScalars.append(UnicodeScalar(byte))
            default:
                let width = switch byte {
                case 0xC2...0xDF: 2
                case 0xE0...0xEF: 3
                case 0xF0...0xF4: 4
                default: 1
                }
                if width > 1 {
                    let end = index + width
                    if end > input.count, !flush {
                        pending = Array(input[index...])
                        break
                    }
                    if end <= input.count, let scalar = String(bytes: input[index..<end], encoding: .utf8) {
                        line += scalar
                        index = end
                        continue
                    }
                }
                line += String(format: "\\x%02x", byte)
            }
            if !pending.isEmpty { break }
            index += 1
        }
        guard !line.isEmpty else { return }
        if !line.hasSuffix("\n") {
            let trailingSpaces = line.reversed().prefix(while: { $0 == " " }).count
            line.removeLast(trailingSpaces)
            line += String(repeating: #"\x20"#, count: trailingSpaces) + "\n"
        }
        try text(line)
    }

    func text(_ string: String) throws {
        try file.write(contentsOf: Data(string.utf8))
    }
}

/// kqueue wakes even if a signal is delivered to another thread. Register
/// before entering raw mode so termination always unwinds the restoration.
private func watch(
    _ queue: Int32, _ identifier: UInt, _ filter: Int16, flags: UInt16 = UInt16(EV_ADD | EV_ENABLE)
) throws {
    var change = kevent(
        ident: identifier, filter: filter, flags: flags,
        fflags: 0, data: 0, udata: nil)
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { throw systemError("register event") }
}

private struct Relay {
    let pty: PTY
    let queue: Int32
    var size: winsize
    var writer: RecordingWriter
    // A paste can fill the child's input buffer while it is writing output.
    // Watch both directions with one bounded pending read from the outer tty.
    private var input = [UInt8](repeating: 0, count: 16 * 1024)
    private var output = [UInt8](repeating: 0, count: 16 * 1024)
    private var inputOffset = 0
    private var inputEnd = 0
    private let inputFD = UInt(STDIN_FILENO)
    private var childFD: UInt { UInt(pty.fileDescriptor) }

    init(pty: PTY, queue: Int32, size: winsize, writer: RecordingWriter) {
        self.pty = pty
        self.queue = queue
        self.size = size
        self.writer = writer
    }

    mutating func run() throws -> Int32 {
        try watch(queue, inputFD, Int16(EVFILT_READ))
        try watch(queue, childFD, Int16(EVFILT_READ))
        try watch(queue, childFD, Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_DISABLE))
        while true {
            var event = kevent()
            if kevent(queue, nil, 0, &event, 1, nil) < 0 {
                if errno == EINTR { continue }
                throw systemError("wait for terminal event")
            }
            if event.filter == EVFILT_SIGNAL, event.ident != UInt(SIGWINCH) {
                _ = pty.signalProcessGroup(Int32(event.ident))
                try writer.flush()
                return 128 + Int32(event.ident)
            }

            try applyResize()
            switch Int32(event.filter) {
            case EVFILT_WRITE:
                try writeInput()
            case EVFILT_READ where event.ident == childFD:
                if try !readOutput() { return try finish() }
            case EVFILT_READ:
                if try !readInput() { return try finish() }
            default:
                break
            }
        }
    }

    private mutating func applyResize() throws {
        // An input or output event can be delivered before the SIGWINCH event.
        // Apply the new size between reads and record it at that boundary.
        let latest = try terminalSize()
        let changedCells = latest.ws_row != size.ws_row || latest.ws_col != size.ws_col
        guard changedCells || latest.ws_xpixel != size.ws_xpixel || latest.ws_ypixel != size.ws_ypixel
        else { return }
        try pty.resize(to: TerminalSize(latest))
        if changedCells {
            try writer.flush()
            try writer.text("@resize \(latest.ws_row) \(latest.ws_col)\n")
        }
        size = latest
    }

    private mutating func readOutput() throws -> Bool {
        let received = try output.withUnsafeMutableBytes { try pty.read(into: $0) }
        guard received > 0 else { return false }
        try output.withUnsafeBytes { buffer in
            let bytes = UnsafeRawBufferPointer(rebasing: buffer.prefix(received))
            try writer.write(bytes)
            try writeToTerminal(bytes)
        }
        return true
    }

    private mutating func readInput() throws -> Bool {
        let received = Darwin.read(STDIN_FILENO, &input, input.count)
        if received < 0 {
            if errno == EINTR { return true }
            throw systemError("read outer terminal")
        }
        guard received > 0 else { return false }
        inputOffset = 0
        inputEnd = received
        try watch(queue, inputFD, Int16(EVFILT_READ), flags: UInt16(EV_DISABLE))
        try watch(queue, childFD, Int16(EVFILT_WRITE), flags: UInt16(EV_ENABLE))
        return true
    }

    private mutating func writeInput() throws {
        // The PTY descriptor is nonblocking and owned by this relay.
        let sent = input.withUnsafeBytes {
            Darwin.write(pty.fileDescriptor, $0.baseAddress! + inputOffset, inputEnd - inputOffset)
        }
        if sent < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            if errno != EIO { throw systemError("write to child terminal") }
            inputOffset = inputEnd
        } else {
            inputOffset += sent
        }
        if inputOffset == inputEnd {
            try watch(queue, childFD, Int16(EVFILT_WRITE), flags: UInt16(EV_DISABLE))
            try watch(queue, inputFD, Int16(EVFILT_READ), flags: UInt16(EV_ENABLE))
        }
    }

    private mutating func finish() throws -> Int32 {
        try writer.flush()
        guard let exit = pty.waitForExit(timeout: .seconds(1)) else {
            throw RecordingError(description: "the PTY closed before its command exited")
        }
        switch exit {
        case .exited(let status): return status
        case .signalled(let signal): return 128 + signal
        }
    }
}

private func makeEventQueue() throws -> Int32 {
    let queue = kqueue()
    guard queue >= 0 else { throw systemError("open terminal event queue") }
    do {
        try watch(queue, UInt(SIGWINCH), Int16(EVFILT_SIGNAL))
        for number in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE] {
            try watch(queue, UInt(number), Int16(EVFILT_SIGNAL))
            signal(number, SIG_IGN)
        }
        return queue
    } catch {
        close(queue)
        throw error
    }
}

private func run(_ arguments: [String]) throws -> Int32 {
    guard arguments.count >= 7, arguments[5] == "--",
          arguments[1..<5].allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
          }) }) else {
        throw RecordingError(
            description: "usage: corta-record OUTPUT CLI VERSION RENDERER CORTA-COMMIT -- COMMAND [ARG ...]")
    }
    var original = termios()
    guard isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw RecordingError(description: "run corta-record interactively inside a Corta pane")
    }
    let initial = try terminalSize()
    let queue = try makeEventQueue()
    defer { close(queue) }

    let output = open(arguments[0], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw systemError("create recording") }
    let file = FileHandle(fileDescriptor: output, closeOnDealloc: true)
    let writer = RecordingWriter(file: file)
    try writer.text("""
        # CLI: \(arguments[1])
        # Version: \(arguments[2])
        # Renderer: \(arguments[3])
        # Corta commit: \(arguments[4])
        @size \(initial.ws_row) \(initial.ws_col)

        """)

    var raw = original
    cfmakeraw(&raw)
    try setMode(&raw)
    defer {
        do {
            try setMode(&original)
        } catch {
            FileHandle.standardError.write(Data("corta-record: \(error)\n".utf8))
        }
    }
    let pty = try PTY.spawn(
        executable: "/usr/bin/env", arguments: Array(arguments.dropFirst(6)),
        environment: ProcessInfo.processInfo.environment,
        size: TerminalSize(initial))
    defer {
        _ = pty.terminate()
        pty.close()
    }
    var relay = Relay(pty: pty, queue: queue, size: initial, writer: writer)
    let status = try relay.run()
    try file.close()
    return status
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("corta-record: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
