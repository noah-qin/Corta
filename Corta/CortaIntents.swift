import AppIntents
import AppKit

/// B16 — the App Intents Corta exposes to the Shortcuts app and, through a
/// Shortcut built there, to `shortcuts run`.
///
/// **No `AppShortcutsProvider`, deliberately.** A provider gives Siri and
/// Spotlight phrases for free, and it also makes the framework register
/// those phrases with the system at every launch. With one in the bundle
/// the test host's main thread stalled for about forty seconds at launch
/// on the hosted CI runner — no user session behind it — and every
/// main-actor suite in the run timed out; without it the run is clean.
/// The intents themselves need no launch-time work: the Shortcuts app
/// reads them from the bundle's metadata.
///
/// **Three verbs, all about surfaces, none about text.** Open a window,
/// focus a window, toggle the Quick Terminal. There is deliberately no
/// "run this command" intent and no parameter that reaches a child's stdin:
/// an automation is an *external* input, and `SECURITY.md` §2 draws one
/// trust boundary around everything that arrives from outside a Corta
/// window — a Shortcut assembled from a web page or a shared file is no
/// more trusted than escape sequences off the PTY. A window's working
/// directory is the one parameter accepted, because it is a path handed
/// to `spawn` as its cwd, checked to exist, and never typed.
///
/// **Windows are named by identity, not by title.** `TerminalWindowEntity`
/// carries `TerminalWindowController.windowID`, minted when the window is
/// created and saved with the arrangement, so a Shortcut that focuses "the
/// build window" resolves to the same window after a relaunch restores it
/// — and to *nothing*, with an error, once that window is gone, rather than
/// to whichever window has a similar title now. Titles are written by the
/// child process and change with every `cd`; nothing resolved by title
/// would stay stable for a minute.
///
/// Everything here runs on the main actor: intents arrive on an arbitrary
/// queue, and every effect is a window operation.
struct TerminalWindowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Corta Window")
    static let defaultQuery = TerminalWindowQuery()

    /// `TerminalWindowController.windowID`.
    let id: String
    /// The window's title at the time the entity was built — display only.
    let title: String

    var displayRepresentation: DisplayRepresentation {
        // A window's title is the child's text, not a string to localise;
        // a `LocalizedStringResource` interpolation here was extracted into
        // the catalog as a bare `%@` key.
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

    /// What the Shortcuts editor offers in its picker: every open window,
    /// in the order they were opened.
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

/// What an intent reports when it cannot do the one thing it is for.
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

/// Opens a new terminal window, optionally in a directory.
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

    /// A file URL naming an existing directory, as a path — or `nil` for
    /// "the home directory". A URL that is not a directory is refused here,
    /// with a message, rather than handed to `spawn` to fail silently into
    /// a home-directory shell the user did not ask for.
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

/// Brings an existing window to the front.
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

/// Shows or hides the Quick Terminal — the same toggle the hotkey performs,
/// for people who would rather bind it in Shortcuts, Raycast or a Stream
/// Deck than have Corta hold a key system-wide.
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
