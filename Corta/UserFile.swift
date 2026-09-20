import Foundation

/// Writes to a file the user owns — a shell rc file, the config file —
/// without changing what that path *is*.
///
/// `String.write(to:atomically:)` replaces the file at the path it is
/// given. When that path is a symbolic link, the link itself is replaced
/// by a plain file and the file it pointed at is left untouched: a
/// `~/.zshrc` kept in a dotfiles repository silently stops being the
/// repository's copy the first time Corta installs its shell integration.
/// The atomic write also creates the replacement with default permissions,
/// so a file the user had made private stops being private.
///
/// `write(_:to:)` follows the link chain to the real file, writes there —
/// still atomically, so a crash mid-write can never leave a truncated rc
/// file — and puts the target's permission bits back afterwards.
nonisolated enum UserFile {
    /// The most links a path is followed through before it is treated as
    /// a loop and written where it stands.
    private static let maximumLinkDepth = 32

    /// Writes `text` to the file `url` ultimately names, creating the
    /// parent directory when needed, atomically, keeping the file's
    /// permissions. A dangling link is followed too: the missing file is
    /// created at its destination and the link stays a link.
    static func write(_ text: String, to url: URL) throws {
        let target = resolvingLinks(url)
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// Follows symbolic links from `url` until a path that is not a link.
    /// Relative link destinations resolve against the link's own directory,
    /// as the kernel resolves them. Unlike `URL.resolvingSymlinksInPath()`
    /// this also follows a link whose destination does not exist yet, so
    /// the file is created where the link points rather than over the link.
    static func resolvingLinks(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        let manager = FileManager.default
        for _ in 0..<maximumLinkDepth {
            guard let attributes = try? manager.attributesOfItem(atPath: current.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                let destination = try? manager.destinationOfSymbolicLink(atPath: current.path)
            else { return current }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                current = current.deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL
            }
        }
        return current
    }
}
