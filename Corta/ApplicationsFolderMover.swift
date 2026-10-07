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

import AppKit

/// Offers to move Corta into `/Applications` when run from elsewhere: a
/// zip has no drag-to-install step, and Sparkle and Spotlight expect
/// `/Applications`. Skipped under `/Applications` or `~/Applications`, from
/// `DerivedData`, or after `suggest-applications-folder = false`.
///
/// Never for the development build (D22), which would land beside the
/// installed app under the same name — not left to a config key a fresh
/// stage wouldn't have.
@MainActor
enum ApplicationsFolderMover {
    static func promptIfNeeded() {
        guard !AppPaths.isDevelopmentBuild else { return }
        guard ConfigurationStore.shared.configuration.suggestApplicationsFolder else { return }
        let bundleURL = Bundle.main.bundleURL
        guard !isUnderApplications(bundleURL), !isDeveloperBuild(bundleURL) else { return }

        // A newer Corta is already installed: replacing it would downgrade it.
        if let installed = installedURL(for: bundleURL), let installedVersion = version(at: installed),
            let ownVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            isVersion(installedVersion, newerThan: ownVersion)
        {
            offerNewerInstall(installed)
            return
        }
        // Gatekeeper runs a quarantined download from a read-only random path
        // (App Translocation): the bundle cannot be moved from there, so the
        // move failed every time. Ask for the drag that removes translocation.
        if isTranslocated(bundleURL) {
            offerManualMove()
            return
        }

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

    /// Under App Translocation's mount: a quarantined app opened where it
    /// was unpacked. Pure, for tests.
    nonisolated static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// Whether build `candidate` is newer than `current`, compared as
    /// dotted numbers. Pure, for tests.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private static func installedURL(for source: URL) -> URL? {
        guard let applications = FileManager.default.urls(
            for: .applicationDirectory, in: .localDomainMask).first
        else { return nil }
        let destination = applications.appendingPathComponent(source.lastPathComponent)
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    private static func version(at bundle: URL) -> String? {
        Bundle(url: bundle)?.infoDictionary?["CFBundleVersion"] as? String
    }

    private static func offerNewerInstall(_ installed: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.text("moveToApplications.newerTitle")
        alert.informativeText = L10n.text("moveToApplications.newerMessage")
        alert.addButton(withTitle: L10n.text("moveToApplications.openNewer"))
        alert.addButton(withTitle: L10n.text("moveToApplications.notNow"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static func offerManualMove() {
        let alert = NSAlert()
        alert.messageText = L10n.text("moveToApplications.title")
        alert.informativeText = L10n.text("moveToApplications.translocatedMessage")
        alert.addButton(withTitle: L10n.text("moveToApplications.openApplicationsFolder"))
        alert.addButton(withTitle: L10n.text("moveToApplications.notNow"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.text("moveToApplications.dontAskAgain")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            ConfigurationStore.shared.update { $0.suggestApplicationsFolder = false }
        }
        guard response == .alertFirstButtonReturn,
            let applications = FileManager.default.urls(
                for: .applicationDirectory, in: .localDomainMask).first
        else { return }
        NSWorkspace.shared.open(applications)
    }

    /// `replaceItemAt`: one atomic move leaving one copy, and it replaces an
    /// existing install without a second prompt.
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
