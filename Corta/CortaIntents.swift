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

import AppIntents
import AppKit

/// The App Intents Corta exposes to Shortcuts (and `shortcuts run`).
///
/// **No `AppShortcutsProvider`.** It registers phrases at every launch,
/// and on the hosted CI runner that stalled the test host's main thread
/// ~40 s. Shortcuts reads intents from bundle metadata without it.
///
/// **Surfaces, never text.** Open, focus, toggle the Quick Terminal; no
/// "run a command", nothing that reaches a child's stdin. Automation is
/// external input (`SECURITY.md` §2). The one parameter is a working
/// directory: a path handed to `spawn`, checked, never typed.
///
/// **Windows by identity.** `TerminalWindowController.windowID` survives a
/// relaunch; a gone window is an error, never a title match — titles are
/// the child's and change on every `cd`.
///
/// Everything runs on the main actor.
struct TerminalWindowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Corta Window")
    static let defaultQuery = TerminalWindowQuery()

    /// `TerminalWindowController.windowID`.
    let id: String
    /// Display only.
    let title: String

    var displayRepresentation: DisplayRepresentation {
        // The child's text, not a localisation key.
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }

    @MainActor
    init(controller: TerminalWindowController) {
        id = controller.windowID
        let title = controller.window?.title ?? ""
        self.title = title.isEmpty ? "Corta" : title
    }
}

struct TerminalWindowQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TerminalWindowEntity] {
        let open = Self.openWindows()
        return identifiers.compactMap { id in open.first { $0.id == id } }
    }

    /// Every open window, in opening order.
    @MainActor
    func suggestedEntities() async throws -> [TerminalWindowEntity] {
        Self.openWindows()
    }

    @MainActor
    static func openWindows() -> [TerminalWindowEntity] {
        guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
        return delegate.terminalWindowControllers.map(TerminalWindowEntity.init)
    }
}

enum CortaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case windowNotFound
    case directoryNotFound(String)
    case windowNotCreated

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .windowNotFound:
            return "That Corta window is no longer open."
        case .directoryNotFound(let path):
            return "\(path) is not a directory."
        case .windowNotCreated:
            return "Corta could not open a window."
        }
    }
}

struct OpenTerminalWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Corta Window"
    static let description = IntentDescription(
        "Opens a new Corta terminal window, in your home directory or in a folder you choose.",
        categoryName: "Windows")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", description: "Where the shell starts. Empty means your home folder.")
    var directory: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Open a Corta window in \(\.$directory)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TerminalWindowEntity> {
        let path = try Self.validatedDirectory(directory)
        guard let delegate = NSApp.delegate as? AppDelegate,
            let controller = delegate.openWindow(workingDirectory: path)
        else { throw CortaIntentError.windowNotCreated }
        NSApp.activate()
        return .result(value: TerminalWindowEntity(controller: controller))
    }

    /// An existing directory's path, or nil for home. Anything else is
    /// refused with a message rather than silently opening home.
    nonisolated static func validatedDirectory(_ url: URL?) throws -> String? {
        guard let url else { return nil }
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw CortaIntentError.directoryNotFound(url.path) }
        return path
    }
}

struct FocusTerminalWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Corta Window"
    static let description = IntentDescription(
        "Brings one of Corta's open windows to the front.", categoryName: "Windows")
    static let openAppWhenRun = true

    @Parameter(title: "Window")
    var window: TerminalWindowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Focus \(\.$window)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate, delegate.focusWindow(id: window.id)
        else { throw CortaIntentError.windowNotFound }
        return .result()
    }
}

/// The hotkey's toggle, for binding outside Corta.
struct ToggleQuickTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Quick Terminal"
    static let description = IntentDescription(
        "Shows the Quick Terminal if it is hidden, and hides it if it is showing.",
        categoryName: "Windows")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickTerminalController.shared.toggle()
        return .result()
    }
}
