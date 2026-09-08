import AppKit
import Foundation

/// M6.1 — the one place the config file is read, written and watched.
///
/// The file is the source of truth, not a cache of some in-memory model:
/// changing a setting writes the file and the change is applied from what
/// comes back, so a click and a hand-edit in `$EDITOR` travel the exact same
/// path. Anything else drifts.
///
/// Watching is a `DispatchSource` on the file itself, plus one on the
/// deepest existing ancestor of its directory. Both are needed: most editors
/// do not write in place, they write a temporary file and rename it over the
/// target, which the file's own descriptor sees as a delete and never as a
/// write — and on a first launch the config's directory may not exist yet,
/// so the watcher starts at an ancestor that does and re-points itself
/// deeper once the missing piece appears.
@MainActor
final class ConfigurationStore {
    static let shared = ConfigurationStore(fileURL: ConfigurationStore.fileURL)

    /// Posted after the configuration changes, from either direction. Panes
    /// observe this rather than being pushed to, so a window opened later
    /// picks up the current values by reading, not by being told.
    static let didChange = Notification.Name("dev.noahqin.Corta.configurationDidChange")

    /// Posted when a write to the config file fails, and again when a later
    /// write succeeds — so a page showing the failure can clear it. The
    /// settings page is the only observer; nothing else can do anything
    /// useful about a read-only home directory.
    static let writeStatusDidChange = Notification.Name(
        "dev.noahqin.Corta.configurationWriteStatusDidChange")

    private(set) var configuration = Configuration()
    /// Why the last write failed, `nil` when the last write succeeded. The
    /// settings page renders this instead of implying a save that did not
    /// happen.
    private(set) var lastWriteError: Error?
    /// Keys from a config written by a different version — carried through a
    /// write so an older Corta does not silently delete a newer one's
    /// settings.
    private var unknownKeys: [(String, String)] = []

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    /// The exact text of our last successful write, so the watcher can tell
    /// the events that write raises apart from an external edit by comparing
    /// contents. A time-based "we are writing" flag was tried first: any
    /// window long enough to cover a slow save also swallows an editor save
    /// that lands inside it.
    private var lastWrittenText: String?
    /// The coalescing timer for watcher events.
    private var pendingReload: DispatchWorkItem?

    /// The file this instance reads, writes and watches — injected so a
    /// test can point a store at a temporary directory instead of the real
    /// config.
    let fileURL: URL

    /// `~/.config/corta/config` — the XDG-ish location a terminal user will
    /// look in first, and one no sandbox container hides.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/corta/config")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
        startWatching()
    }

    isolated deinit {
        pendingReload?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    // MARK: - Reading

    /// Reads the file. An absent file — the normal first-launch state, or a
    /// deletion under a running Corta — means the defaults, so no surface
    /// keeps reporting settings that nothing persists. A read or decode
    /// failure takes the same path: a config Corta cannot read is no config.
    func reload() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            unknownKeys = []
            let defaults = Configuration()
            guard configuration != defaults else { return }
            configuration = defaults
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        let (parsed, unknown) = Configuration.parse(text)
        unknownKeys = unknown
        guard parsed != configuration else { return }
        configuration = parsed
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Writing

    /// Applies a change by writing the file and reading the result back. The
    /// settings page calls this; nothing sets `configuration` directly.
    ///
    /// Returns whether the change was persisted. A failed write is rolled
    /// back rather than kept in memory: the file is the source of truth, so a
    /// value the file does not hold is a value the next reload discards — and
    /// keeping it would make every surface report a setting that will not
    /// survive a relaunch, which is exactly the drift the single-store rule
    /// exists to prevent. No `didChange` is posted for a change that did not
    /// happen; `writeStatusDidChange` is, so the settings page can say why.
    @discardableResult
    func update(_ mutate: (inout Configuration) -> Void) -> Bool {
        var updated = configuration
        mutate(&updated)
        guard updated != configuration else { return true }
        let previous = configuration
        configuration = updated
        guard write() else {
            configuration = previous
            return false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    /// Creates the file with the current values — what the settings page's
    /// "Reveal in Finder" needs, and what makes the format discoverable on a
    /// first launch.
    @discardableResult
    func write() -> Bool {
        let url = fileURL
        let text = configuration.serialized(preserving: unknownKeys)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            noteWriteResult(error)
            return false
        }
        lastWrittenText = text
        noteWriteResult(nil)
        // An atomic write replaces the inode, so the descriptor the file
        // watcher holds now points at a file nothing will ever write again.
        startWatching()
        return true
    }

    /// Records the outcome and posts only on a transition, so a page bound to
    /// the notification is not rebuilt on every successful keystroke.
    private func noteWriteResult(_ error: Error?) {
        let wasFailing = lastWriteError != nil
        lastWriteError = error
        guard wasFailing != (error != nil) else { return }
        NotificationCenter.default.post(name: Self.writeStatusDidChange, object: nil)
    }

    // MARK: - Watching

    private func startWatching() {
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = watch(fileURL, mask: [.write, .extend, .delete, .rename])
        directorySource = watch(
            Self.deepestExistingDirectory(under: fileURL.deletingLastPathComponent()),
            mask: [.write, .delete, .rename])
    }

    /// The nearest ancestor of `url` that exists. The config's directory is
    /// created on first write, so at launch there may be nothing to watch
    /// but its parent — and that parent's `.write` is exactly the event that
    /// says the directory (and then the file) has appeared.
    private static func deepestExistingDirectory(under url: URL) -> URL {
        var url = url
        while url.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: url.path)
        {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent)
        -> DispatchSourceFileSystemObject?
    {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Our own write raises these events too, and it needs no reload:
            // the store already holds exactly those values. Compare contents
            // rather than suppressing events for a window, so an external
            // edit that lands moments after our write is not swallowed.
            if let written = self.lastWrittenText {
                if (try? String(contentsOf: self.fileURL, encoding: .utf8)) == written {
                    return
                }
                // The file no longer holds what we wrote — an external edit
                // owns it now, and later events must not be measured against
                // our text.
                self.lastWrittenText = nil
            }
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
