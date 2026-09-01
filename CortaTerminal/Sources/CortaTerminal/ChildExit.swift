import Darwin

/// How a child process ended.
public enum ChildExit: Equatable, Sendable {
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

    /// True for a normal exit with status 0.
    public var isCleanExit: Bool { self == .exited(code: 0) }
}
