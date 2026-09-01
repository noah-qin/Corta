import Darwin
import Testing

@testable import CortaTerminal

/// Test helpers. Everything here drives a *real* pty and a *real* child
/// process: the whole point of M1.1 is that the system calls are right, and a
/// mock would only assert that our mock matches our beliefs.
enum PTYFixture {
    /// `/bin/sh -c script`, on a pty of the given size.
    static func shell(
        _ script: String,
        size: TerminalSize = TerminalSize(),
        terminationHandler: (@Sendable (ChildExit) -> Void)? = nil
    ) throws -> PTY {
        try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", script],
            size: size,
            terminationHandler: terminationHandler
        )
    }
}

extension PTY {
    /// Reads until `isSatisfied` accepts the accumulated output, the child
    /// closes the pty, or `timeout` elapses.
    ///
    /// Uses `poll` so a wedged child fails the test instead of hanging it.
    func readOutput(
        timeout: Duration = .seconds(10),
        until isSatisfied: (String) -> Bool = { _ in false }
    ) -> String {
        var accumulated = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let milliseconds = Int32(
                clamping: remaining.components.seconds * 1000
                    + remaining.components.attoseconds / 1_000_000_000_000_000
            )
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, max(milliseconds, 1))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }  // timed out

            let count = buffer.withUnsafeMutableBytes { bytes in
                (try? read(into: bytes)) ?? 0
            }
            if count == 0 { break }  // end of file
            accumulated.append(contentsOf: buffer[0..<count])
            if isSatisfied(String(decoding: accumulated, as: UTF8.self)) { break }
        }
        return String(decoding: accumulated, as: UTF8.self)
    }

    /// Reads until the output contains `needle`, or the timeout expires.
    func readOutput(containing needle: String, timeout: Duration = .seconds(10)) -> String {
        readOutput(timeout: timeout) { $0.contains(needle) }
    }

    /// Writes `text` to the child's terminal.
    func write(text: String) throws {
        let bytes = Array(text.utf8)
        _ = try bytes.withUnsafeBytes { try writeAll($0) }
    }
}

/// The whitespace-separated fields of `text`, for parsing command output.
func fields(of text: String) -> [String] {
    text.split(whereSeparator: \Character.isWhitespace)
        .map(String.init)
}
