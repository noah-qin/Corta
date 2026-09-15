import Cocoa
import CortaTerminal

/// B14 — following `path:line[:column]` references in a *remote* pane.
///
/// B13's rule was refusal: `workingDirectory` is nil for a remote pane
/// precisely so a remote path can never be opened as a local file. Remote
/// editing turns the refusal into a redirection: a reference in a `.remote`
/// pane resolves against the pane's *remote* directory (the OSC 7 report's
/// own answer, the same honesty bar as everything else in B13), the remote
/// file is downloaded to its managed local copy (`RemoteEditStore`/
/// `RemoteEditCoordinator`), and the editor opens on the copy with the
/// reference's line and column. Editing the copy and what goes back to the
/// remote are the coordinator's explicit-upload machinery; nothing here
/// writes anything anywhere but the managed copy.
///
/// What is still refused: `.remoteUnknown` (no host to download from),
/// `.unknown`, and `~`-relative paths (the remote account's home is not
/// knowable from here, and guessing it would be the old bug wearing a new
/// feature).
extension ViewController {
    /// A reference resolved to a remote host and path — the remote
    /// counterpart of `ResolvedFileReference`.
    nonisolated struct ResolvedRemoteReference: Equatable {
        var host: String
        var remotePath: String
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves a detected reference against a remote pane's host and
    /// directory, or refuses. Static and pure, like the local `resolve`.
    nonisolated static func resolveRemote(
        _ reference: FileReferenceDetection.Reference, state: PaneRemoteState
    ) -> ResolvedRemoteReference? {
        guard case .remote(let host, let directory, _) = state else { return nil }
        let path = reference.path
        // "~" would be the remote account's home; nothing here knows it.
        guard !path.hasPrefix("~") else { return nil }
        let absolute =
            path.hasPrefix("/") ? path : RemotePath.join(directory, path)
        return ResolvedRemoteReference(
            host: host, remotePath: RemotePath.normalized(absolute),
            line: reference.line, column: reference.column, range: reference.range)
    }

    /// The remote reference under a mouse event, or `nil` — the remote
    /// counterpart of `fileReferenceUnder`, sharing its hit-testing.
    func remoteFileReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> ResolvedRemoteReference?
    {
        guard let reference = detectedReferenceUnder(event, in: terminalView) else { return nil }
        return Self.resolveRemote(reference, state: paneRemoteState)
    }

    /// The remote reference in `effectiveCommand`'s output — the remote
    /// counterpart of `fileReferenceInCommand(_:)`, sharing its bounded
    /// walk.
    func remoteFileReferenceInCommand(_ record: CommandRecord?) -> ResolvedRemoteReference? {
        guard let reference = detectedReferenceInCommand(record) else { return nil }
        return Self.resolveRemote(reference, state: paneRemoteState)
    }

    /// Downloads (or reuses) the managed copy and opens the editor on it —
    /// asynchronously, since the download is a network round trip. The
    /// click/command is consumed either way; failures surface as toasts
    /// with the typed error's own wording, exactly as the browser shows
    /// them.
    @discardableResult
    func openRemote(_ reference: ResolvedRemoteReference) -> Bool {
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await RemoteEditCoordinator.shared.open(
                    host: reference.host, remotePath: reference.remotePath,
                    line: reference.line, column: reference.column)
                if !opened {
                    terminalView?.showToast(
                        L10n.text("toast.badOpenFileCommand"), kind: .warning)
                }
            } catch {
                let error = SFTPBrowserModel.sftpError(error)
                // A declined first connection (`RemoteHostConsent`) is the
                // user's answer, not a failure to report.
                if case .cancelled = error { return }
                terminalView?.showToast(
                    SFTPBrowserModel.errorMessage(error, host: reference.host), kind: .warning)
            }
        }
        return true
    }
}

/// Remote POSIX path arithmetic — string-level only, never touching the
/// local filesystem's rules (`NSString.standardizingPath` is the *local*
/// standardizer; a remote path is not this machine's to standardize).
enum RemotePath {
    /// `join("/srv/app", "main.rs")` → `/srv/app/main.rs`; the root is the
    /// only directory that already ends in a separator.
    nonisolated static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// Resolves `.` and `..` segments and collapses repeated separators, so
    /// the path the editor flow downloads is the path the manifest records
    /// — `src/../Makefile` and `Makefile` are one remote file, and must be
    /// one managed copy.
    nonisolated static func normalized(_ path: String) -> String {
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                // At the root there is nothing to pop; `..` stays put, as
                // POSIX resolves it.
                if !segments.isEmpty { segments.removeLast() }
            default:
                segments.append(String(segment))
            }
        }
        return "/" + segments.joined(separator: "/")
    }
}
