import Foundation
import Synchronization

/// The seam between the SFTP engine and the app's browser/transfer
/// UI.
///
/// `SFTPSession` and `SFTPTransferEngine` are concrete classes: the engine's
/// own tests drive them through `SFTPChannelTransport` (a fake server on the
/// other end of an in-memory pipe), which is the right seam for protocol
/// work. The app layer needs a different one — its models orchestrate
/// connect/list/transfer and must be testable with no ssh, no network and
/// no in-memory wire protocol at all. `SFTPClient` is that seam: the exact
/// surface `SFTPBrowserModel` consumes, at the granularity the UI thinks in
/// (a directory listing, a transfer), so a fake answers in those terms
/// rather than by speaking SFTPv3.
///
/// `SFTPConnection` is the real implementation: one host, one session, one
/// transfer engine, and the reconnect closure the engine requires — which
/// only this layer can supply, because re-running ssh (and its
/// authentication) is a spawn, and spawning belongs here.
public protocol SFTPClient: AnyObject, Sendable {
    /// The server's capabilities, from its VERSION answer; `nil` until
    /// `connect()` completes.
    var capabilities: SFTPServerCapabilities? { get }

    /// Spawns the channel and completes the INIT/VERSION handshake.
    /// A second call on a live connection answers from the first.
    @discardableResult
    func connect() async throws(SFTPError) -> SFTPServerCapabilities

    /// REALPATH (§8.9), decoded lossily — for display and navigation only;
    /// the canonical-bytes form stays on the session for anything the wire
    /// cares about.
    func realPath(path: String) async throws(SFTPError) -> String

    /// The whole directory: READDIR batches until EOF, `.` and `..`
    /// included exactly as the server sent them (filtering is a display
    /// decision).
    func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry]

    func makeDirectory(path: String) async throws(SFTPError)
    /// A file, never a directory.
    func remove(path: String) async throws(SFTPError)
    /// A directory, which the server requires to be empty.
    func removeDirectory(path: String) async throws(SFTPError)
    /// Version 3 semantics: fails when the destination exists.
    func rename(from oldPath: String, to newPath: String) async throws(SFTPError)
    /// LSTAT: does not follow symbolic links.
    func lstat(path: String) async throws(SFTPError) -> SFTPAttributes

    /// Filesystem capacity, or `nil` when the server does not support
    /// `statvfs@openssh.com` — reported unavailable, never guessed.
    func volumeInfo(path: String) async throws(SFTPError) -> SFTPVolumeInfo?

    /// One atomic transfer each way — see `SFTPTransferEngine` for what the
    /// partial file, the conflict policy and the progress callback mean.
    /// Cancellation is `Task` cancellation of the awaiting call.
    @discardableResult
    func download(
        remotePath: String, to localDestination: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt

    @discardableResult
    func upload(
        from localSource: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt

    /// Whole trees, one atomic file transfer at a time — see
    /// `SFTPTransferEngine.downloadDirectory`/`uploadDirectory` for what
    /// merges, what is skipped and how the policy applies per file.
    @discardableResult
    func downloadDirectory(
        remotePath: String, to localDirectory: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt

    @discardableResult
    func uploadDirectory(
        from localDirectory: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt

    /// Ends the session and the channel behind it. Idempotent.
    func close()
}

/// The real `SFTPClient`: `ssh -s -- <host> sftp` behind a session behind a
/// transfer engine, carrying the reconnect the engine's retry policy needs.
///
/// One refinement over the raw engine: a `.transport(.connectionLost)` that
/// surfaces *after* the ssh child has exited is reclassified through
/// `SFTPTransportError.classify(exit:diagnostics:)` before the caller sees
/// it. The channel's reader deliberately never does this — mid-stream it
/// cannot distinguish "the server hung up" from "ssh died" — but once a
/// failure has been delivered, the exit status is a fact, and "Permission
/// denied (publickey)" deserves to reach the user as an authentication
/// failure rather than as a lost connection.
public final class SFTPConnection: SFTPClient, @unchecked Sendable {
    public let host: String
    private let sshExecutable: String

    private struct State {
        /// The channel the engine's *current* session runs over — the
        /// reconnect closure keeps this pointed at the live one, so error
        /// reclassification reads the right child's diagnostics.
        var channel: SFTPSubprocessChannel?
        var engine: SFTPTransferEngine?
        var capabilities: SFTPServerCapabilities?
    }

    private let state = Mutex(State())

    /// `arguments`, when given, replaces the `ssh -s -- <host> sftp` argv
    /// outright — the seam that lets `/usr/libexec/sftp-server -d <dir>`
    /// stand in for ssh in `SFTPRealServerTests`. Production passes
    /// neither.
    private let arguments: [String]?

    public init(
        host: String, sshExecutable: String = SFTPSubprocessChannel.defaultSSHPath,
        arguments: [String]? = nil
    ) {
        self.host = host
        self.sshExecutable = sshExecutable
        self.arguments = arguments
    }

    public var capabilities: SFTPServerCapabilities? {
        state.withLock { $0.capabilities }
    }

    @discardableResult
    public func connect() async throws(SFTPError) -> SFTPServerCapabilities {
        if let existing = state.withLock({ $0.capabilities }) { return existing }
        let (channel, session) = try await openSession()
        let engine = SFTPTransferEngine(session: session) { [weak self] in
            // The engine calls this between attempts, after a transport
            // failure: a fresh ssh, a fresh session, and the connection's
            // channel pointer moved to the live child.
            guard let self else { throw SFTPError.cancelled }
            let (channel, session) = try await self.openSession()
            self.state.withLock { $0.channel = channel }
            return session
        }
        // connect() inside openSession() already stored the capabilities.
        guard let capabilities = session.capabilities else {
            throw SFTPError.protocolViolation("connected session reported no capabilities")
        }
        state.withLock { state in
            state.channel = channel
            state.engine = engine
            state.capabilities = capabilities
        }
        return capabilities
    }

    /// Spawns a fresh channel and connects a session over it. A failed
    /// connect closes the session — which kills and reaps the ssh child —
    /// so a refused connection never lingers, and the failure is
    /// reclassified from the child's exit before it propagates.
    private func openSession() async throws(SFTPError) -> (SFTPSubprocessChannel, SFTPSession) {
        let channel: SFTPSubprocessChannel
        do {
            channel = try SFTPSubprocessChannel.spawn(
                host: host, executable: sshExecutable, arguments: arguments)
        } catch {
            throw .transport(error)
        }
        let session = SFTPSession(transport: channel)
        do {
            _ = try await session.connect()
        } catch {
            session.close()
            // *This* channel, by hand: the connection's pointer is moved to
            // a child only once its session is up, so on the first connect
            // there is nothing in `state` yet and `classified(_:)` alone
            // would hand back the bare `.connectionLost`. A password prompt
            // ssh could not show would then read "The connection was lost"
            // in the browser, and never reach the "connect once in the
            // terminal first" guidance.
            throw await classified(error, over: channel)
        }
        return (channel, session)
    }

    public func realPath(path: String) async throws(SFTPError) -> String {
        String(decoding: try await engine().session.realPath(path: path), as: UTF8.self)
    }

    public func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        try await classify { try await engine().listDirectory(path: path) }
    }

    public func makeDirectory(path: String) async throws(SFTPError) {
        try await classify { try await engine().makeDirectory(path: path) }
    }

    public func remove(path: String) async throws(SFTPError) {
        try await classify { try await engine().remove(path: path) }
    }

    public func removeDirectory(path: String) async throws(SFTPError) {
        try await classify { try await engine().removeDirectory(path: path) }
    }

    public func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        try await classify { try await engine().rename(from: oldPath, to: newPath) }
    }

    public func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await classify { try await engine().lstat(path: path) }
    }

    public func volumeInfo(path: String) async throws(SFTPError) -> SFTPVolumeInfo? {
        try await classify { try await engine().volumeInfo(path: path) }
    }

    @discardableResult
    public func download(
        remotePath: String, to localDestination: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        try await classify {
            try await engine().download(
                remotePath: remotePath, to: localDestination, policy: policy,
                partialDisposition: partialDisposition, progress: progress)
        }
    }

    @discardableResult
    public func upload(
        from localSource: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        try await classify {
            try await engine().upload(
                from: localSource, to: remotePath, policy: policy,
                partialDisposition: partialDisposition, progress: progress)
        }
    }

    @discardableResult
    public func downloadDirectory(
        remotePath: String, to localDirectory: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        try await classify {
            try await engine().downloadDirectory(
                remotePath: remotePath, to: localDirectory, policy: policy, progress: progress)
        }
    }

    @discardableResult
    public func uploadDirectory(
        from localDirectory: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        try await classify {
            try await engine().uploadDirectory(
                from: localDirectory, to: remotePath, policy: policy, progress: progress)
        }
    }

    public func close() {
        let drained = state.withLock { state -> State in
            defer {
                state.channel = nil
                state.engine = nil
                state.capabilities = nil
            }
            return state
        }
        // The engine's session may be a reconnect-installed replacement
        // whose channel this object never held; closing it covers that
        // case, and closing the tracked channel covers the rest. Both are
        // idempotent.
        drained.engine?.session.close()
        drained.channel?.close()
    }

    deinit {
        close()
    }

    private func engine() throws(SFTPError) -> SFTPTransferEngine {
        guard let engine = state.withLock({ $0.engine }) else {
            throw .protocolViolation("SFTPConnection used before connect()")
        }
        return engine
    }

    /// Runs one engine call, reclassifying a lost connection from the
    /// child's exit. The closure is untyped-throws because this toolchain
    /// does not infer typed throws into closure arguments; anything that
    /// is not already an `SFTPError` is a bug in the engine, reported as a
    /// violation rather than silently relabelled.
    private func classify<T>(
        _ body: () async throws -> T
    ) async throws(SFTPError) -> T {
        do {
            return try await body()
        } catch let error as SFTPError {
            throw await classified(error)
        } catch {
            throw .protocolViolation("\(error)")
        }
    }

    /// A lost connection over a dead ssh child is really whatever the
    /// child's exit said — authentication, reachability, an ssh-level
    /// failure — so the UI's wording can name the actual class.
    private func classified(
        _ error: SFTPError, over channel: SFTPSubprocessChannel? = nil
    ) async -> SFTPError {
        guard case .transport(.connectionLost) = error,
            let channel = channel ?? state.withLock({ $0.channel }),
            let exit = channel.awaitExit()
        else { return error }
        return .transport(SFTPTransportError.classify(exit: exit, diagnostics: channel.diagnosticOutput))
    }
}
