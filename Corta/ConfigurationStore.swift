import AppKit
import Foundation

/// M6.1 — the one place the config file is read, written and watched.
///
/// The file is the source of truth, not a cache of some in-memory model:
/// changing a setting writes the file and the change is applied from what
/// comes back, so a click and a hand-edit in `$EDITOR` travel the exact same
/// path. Anything else drifts.
///
/// Watching is a `DispatchSource` on the file itself, plus one on its
/// directory. Both are needed: most editors do not write in place, they
/// write a temporary file and rename it over the target, which the file's
/// own descriptor sees as a delete and never as a write.
@MainActor
final class ConfigurationStore {
    static let shared = ConfigurationStore()

    /// Posted after the configuration changes, from either direction. Panes
    /// observe this rather than being pushed to, so a window opened later
    /// picks up the current values by reading, not by being told.
    static let didChange = Notification.Name("dev.noahqin.Corta.configurationDidChange")

    private(set) var configuration = Configuration()
    /// Keys from a config written by a different version — carried through a
    /// write so an older Corta does not silently delete a newer one's
    /// settings.
    private var unknownKeys: [(String, String)] = []

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    /// Set around our own write, so the watcher does not treat it as an
    /// external edit and reload in the middle of applying one.
    private var isWriting = false
    /// The coalescing timer for watcher events.
    private var pendingReload: DispatchWorkItem?

    /// `~/.config/corta/config` — the XDG-ish location a terminal user will
    /// look in first, and one no sandbox container hides.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/corta/config")
    }

    private init() {
        reload()
        startWatching()
    }

    // MARK: - Reading

    /// Reads the file, or keeps the defaults when there is none. A missing
    /// config is the normal first-launch state, not an error.
    func reload() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let (parsed, unknown) = Configuration.parse(text)
        unknownKeys = unknown
        guard parsed != configuration else { return }
        configuration = parsed
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Writing

    /// Applies a change by writing the file and reading the result back. The
    /// settings page calls this; nothing sets `configuration` directly.
    func update(_ mutate: (inout Configuration) -> Void) {
        var updated = configuration
        mutate(&updated)
        guard updated != configuration else { return }
        configuration = updated
        write()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Creates the file with the current values — what the settings page's
    /// "Reveal in Finder" needs, and what makes the format discoverable on a
    /// first launch.
    @discardableResult
    func write() -> Bool {
        let url = Self.fileURL
        isWriting = true
        defer {
            // The watcher fires asynchronously; clear the flag after it
            // would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.isWriting = false }
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configuration.serialized(preserving: unknownKeys)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        // An atomic write replaces the inode, so the descriptor the file
        // watcher holds now points at a file nothing will ever write again.
        startWatching()
        return true
    }

    // MARK: - Watching

    private func startWatching() {
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = watch(Self.fileURL, mask: [.write, .extend, .delete, .rename])
        directorySource = watch(
            Self.fileURL.deletingLastPathComponent(), mask: [.write, .delete, .rename])
    }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent)
        -> DispatchSourceFileSystemObject?
    {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.isWriting else { return }
            // Coalesce: an editor's save is often several events in a row,
            // and re-reading per event would apply the file mid-rewrite.
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadFromWatcher() }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func reloadFromWatcher() {
        // The inode may have been replaced by an atomic save; re-point the
        // watchers before reading, or the next edit goes unseen.
        startWatching()
        reload()
    }
}
