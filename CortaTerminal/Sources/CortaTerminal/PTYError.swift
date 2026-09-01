import Darwin

/// A failure in the pty layer. Every case carries the `errno` the system
/// call reported, because that is the only detail worth acting on.
public enum PTYError: Error, Equatable {
    /// `posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r` or `open` failed.
    case openFailed(code: Int32)
    /// `posix_spawn` or one of its setup calls failed.
    case spawnFailed(code: Int32)
    /// `read` or `write` failed.
    case ioFailed(code: Int32)
    /// `ioctl(TIOCSWINSZ)` failed.
    case resizeFailed(code: Int32)
    /// The primary descriptor has already been closed.
    case closed
    /// The executable path was not absolute. `posix_spawn` does not search
    /// `PATH`, and resolving it here would be a second, subtler code path.
    case executablePathNotAbsolute
}

extension PTYError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .openFailed(let code): "opening a pty failed: \(Self.message(code))"
        case .spawnFailed(let code): "spawning the child failed: \(Self.message(code))"
        case .ioFailed(let code): "pty I/O failed: \(Self.message(code))"
        case .resizeFailed(let code): "setting the window size failed: \(Self.message(code))"
        case .closed: "the pty is closed"
        case .executablePathNotAbsolute: "the executable path must be absolute"
        }
    }

    private static func message(_ code: Int32) -> String {
        guard let c = strerror(code) else { return "errno \(code)" }
        return "\(String(cString: c)) (errno \(code))"
    }
}
