import AppKit

/// Offers to move Corta into `/Applications` on launch when it is running
/// from anywhere else — Downloads, wherever a `.zip` happened to be
/// extracted, the Desktop. Direct-download distribution (M6.16) ships a
/// plain archive with no drag-to-install step a `.dmg` would give a user;
/// without this, a person who never drags the app anywhere keeps running
/// it from wherever it landed. That matters beyond tidiness: Sparkle's
/// update path (`UpdateController`) and Spotlight/Launchpad's assumptions
/// about where an "installed" app lives both expect `/Applications`.
///
/// Skipped when already under `/Applications` or `~/Applications` — the
/// common case after the first launch, or a manual drag — when running
/// from Xcode's `DerivedData` (a developer build has nowhere else to
/// live), and when the user has already said not to ask again
/// (`suggest-applications-folder` in the config file).
@MainActor
enum ApplicationsFolderMover {
    static func promptIfNeeded() {
        guard ConfigurationStore.shared.configuration.suggestApplicationsFolder else { return }
        let bundleURL = Bundle.main.bundleURL
        guard !isUnderApplications(bundleURL), !isDeveloperBuild(bundleURL) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.text("moveToApplications.title")
        alert.informativeText = L10n.text("moveToApplications.message")
        alert.addButton(withTitle: L10n.text("moveToApplications.move"))
        alert.addButton(withTitle: L10n.text("moveToApplications.notNow"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.text("moveToApplications.dontAskAgain")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            ConfigurationStore.shared.update { $0.suggestApplicationsFolder = false }
        }
        guard response == .alertFirstButtonReturn else { return }
        move(bundleURL)
    }

    private static func isUnderApplications(_ url: URL) -> Bool {
        FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .contains { url.path.hasPrefix($0.path + "/") }
    }

    private static func isDeveloperBuild(_ url: URL) -> Bool {
        url.path.contains("/Xcode/DerivedData/")
    }

    /// `replaceItemAt` rather than a copy-then-trash pair: one atomic
    /// operation that leaves exactly one copy on disk — the source is
    /// consumed as part of the replace, not left behind as a duplicate in
    /// Downloads — and an existing `/Applications/Corta.app` (a manual
    /// re-download over a previous install) is swapped for the new one
    /// rather than requiring its own separate "already exists" prompt.
    private static func move(_ source: URL) {
        guard
            let applicationsURL = FileManager.default.urls(
                for: .applicationDirectory, in: .localDomainMask
            ).first
        else { return }
        let destination = applicationsURL.appendingPathComponent(source.lastPathComponent)
        do {
            let finalURL =
                try FileManager.default.replaceItemAt(destination, withItemAt: source) ?? destination
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: finalURL, configuration: configuration) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = L10n.text("moveToApplications.failedTitle")
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }
}
