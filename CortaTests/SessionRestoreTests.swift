import AppKit
import Foundation
import Testing

@testable import Corta

/// S05 — restoring must never hand a directory to a local spawn unless it
/// names a local directory: state saved before OSC 7 reports were
/// host-filtered can still carry a remote machine's path, and a directory on
/// a volume that has gone away is just as unusable.
struct SessionRestoreTests {
    @Test("a pane directory that exists locally is kept")
    func existingDirectoryIsKept() {
        let layout = PaneLayout.pane(directory: "/tmp")
        #expect(layout.droppingMissingDirectories() == layout)
        #expect(layout.droppingMissingDirectories().firstDirectory == "/tmp")
    }

    @Test("a pane directory that does not exist locally is dropped")
    func missingDirectoryIsDropped() {
        // What a remote host's OSC 7 report looks like by load time — the
        // host is gone, only the path remains.
        let layout = PaneLayout.pane(directory: "/remote/hosts/are/not/here")
        #expect(layout.droppingMissingDirectories() == .pane(directory: nil))
        #expect(layout.droppingMissingDirectories().firstDirectory == nil)
    }

    @Test("a nil directory stays nil")
    func nilDirectoryStaysNil() {
        let layout = PaneLayout.pane(directory: nil)
        #expect(layout.droppingMissingDirectories() == layout)
    }

    // MARK: - Preset identity and focus (B09)

    @Test("presetName and isFocused round-trip through validation and directory-dropping")
    func presetAndFocusSurviveRepair() {
        let layout = PaneLayout.pane(
            directory: "/tmp", presetName: "work", isFocused: true)
        let repaired = layout.validated().droppingMissingDirectories()
        #expect(repaired.firstPresetName == "work")
        guard case .pane(_, let presetName, let isFocused) = repaired else {
            Issue.record("expected a pane")
            return
        }
        #expect(presetName == "work")
        #expect(isFocused)
    }

    @Test("a dropped directory keeps its preset name and focus flag")
    func droppingDirectoryPreservesPresetAndFocus() {
        let layout = PaneLayout.pane(
            directory: "/no/such/directory", presetName: "work", isFocused: true)
        guard case .pane(let directory, let presetName, let isFocused) =
            layout.droppingMissingDirectories()
        else {
            Issue.record("expected a pane")
            return
        }
        #expect(directory == nil)
        #expect(presetName == "work")
        #expect(isFocused)
    }

    @Test("old JSON with no presetName or isFocused decodes with honest defaults")
    func oldPaneJSONDecodesWithDefaults() throws {
        let json = Data(#"{"pane": {"directory": "/tmp"}}"#.utf8)
        let layout = try JSONDecoder().decode(PaneLayout.self, from: json)
        #expect(layout == .pane(directory: "/tmp", presetName: nil, isFocused: false))
    }

    @Test("filtering recurses through splits and keeps their shape")
    func splitsAreFiltered() {
        let layout = PaneLayout.split(
            vertical: true, position: 0.25,
            first: .pane(directory: "/tmp"),
            second: .split(
                vertical: false, position: 0.75,
                first: .pane(directory: "/no/such/directory"),
                second: .pane(directory: nil)))
        #expect(
            layout.droppingMissingDirectories()
                == .split(
                    vertical: true, position: 0.25,
                    first: .pane(directory: "/tmp"),
                    second: .split(
                        vertical: false, position: 0.75,
                        first: .pane(directory: nil),
                        second: .pane(directory: nil))))
    }
}


/// U07 — a restore reads a file the user can edit and a crash can truncate,
/// so the geometry and the tree shape it names are validated rather than
/// trusted, and a restore that dies is not tried a second time.
@MainActor
struct RestoreValidationTests {
    // MARK: - Geometry

    @Test("a saved frame that could not have come from a window is replaced")
    func unusableFramesAreReplaced() {
        #expect(WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)).isUsable)
        #expect(!WindowState.Frame(NSRect(x: 0, y: 0, width: 0, height: 0)).isUsable)
        // Set on the field, not through the rect: `CGRect.width` reports the
        // standardized (absolute) width, so a negative one never survives
        // the initialiser — but it can be typed straight into the JSON.
        var negative = WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560))
        negative.width = -900
        #expect(!negative.isUsable)
        // 40 points high is a titlebar, not a terminal.
        #expect(!WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 40)).isUsable)
    }

    /// `NaN` is the case that matters: `min`/`max` propagate it silently, so
    /// a non-finite frame would survive the on-screen clamp untouched and
    /// reach `NSWindow.setFrame`.
    @Test("a non-finite frame does not survive the on-screen clamp")
    func nonFiniteFramesAreReplaced() {
        var frame = WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560))
        frame.width = .nan
        #expect(!frame.isUsable)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let result = frame.onScreen([])
        #expect(result.width.isFinite)
        #expect(result.height.isFinite)
        #expect(result.width >= WindowState.Frame.minimumSize.width)
        _ = screen
    }

    // MARK: - Tree shape

    @Test("a divider fraction outside the usable range is clamped")
    func dividerFractionsAreClamped() {
        let flush = PaneLayout.split(
            vertical: true, position: 0, first: .pane(directory: nil),
            second: .pane(directory: nil))
        guard case .split(_, let position, _, _) = flush.validated() else {
            Issue.record("expected a split")
            return
        }
        #expect(position == PaneLayout.dividerRange.lowerBound)

        let past = PaneLayout.split(
            vertical: false, position: 4, first: .pane(directory: nil),
            second: .pane(directory: nil))
        guard case .split(_, let clamped, _, _) = past.validated() else {
            Issue.record("expected a split")
            return
        }
        #expect(clamped == PaneLayout.dividerRange.upperBound)
    }

    @Test("a non-finite divider fraction becomes a centred split")
    func nonFiniteDividerIsCentred() {
        let layout = PaneLayout.split(
            vertical: true, position: .nan, first: .pane(directory: nil),
            second: .pane(directory: nil))
        guard case .split(_, let position, _, _) = layout.validated() else {
            Issue.record("expected a split")
            return
        }
        #expect(position == 0.5)
    }

    /// The cap is not about how many panes a person wants; it is about a
    /// truncated or hostile state file recursing every walk over the tree
    /// until the stack runs out.
    @Test("nesting past the depth cap collapses to a pane")
    func deepNestingCollapses() {
        var layout = PaneLayout.pane(directory: "/tmp")
        for _ in 0..<40 {
            layout = .split(
                vertical: true, position: 0.5, first: layout, second: .pane(directory: nil))
        }
        func depth(_ layout: PaneLayout) -> Int {
            switch layout {
            case .pane: return 0
            case .split(_, _, let first, let second): return 1 + max(depth(first), depth(second))
            }
        }
        #expect(depth(layout) == 40)
        #expect(depth(layout.validated()) == PaneLayout.maximumDepth)
    }

    @Test("a valid tree is returned unchanged")
    func validTreesAreUntouched() {
        let layout = PaneLayout.split(
            vertical: true, position: 0.5,
            first: .pane(directory: "/tmp"), second: .pane(directory: nil))
        #expect(layout.validated() == layout)
    }

    // MARK: - The crash marker

    /// A crash *during* a restore must not replay the layout that caused it;
    /// a crash at any other time must still find the arrangement waiting.
    /// One marker file separates the two — the state file used to be deleted
    /// at launch to get the first property, which cost the second (U07).
    @Test("a restore that never finished is not tried again")
    func anInterruptedRestoreIsNotRetried() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(!SessionRestore.previousRestoreFailed)
        SessionRestore.beginRestore()
        #expect(SessionRestore.previousRestoreFailed)
        // A completed restore clears it, so the next launch restores again.
        SessionRestore.endRestore()
        #expect(!SessionRestore.previousRestoreFailed)
    }

    /// The arrangement survives a write and a read, so a crash after launch
    /// has something to come back to.
    @Test("the saved arrangement round-trips through the state file")
    func savedStateRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }

        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 100, y: 120, width: 900, height: 560)),
            layout: .split(
                vertical: true, position: 0.4,
                first: .pane(directory: "/tmp"), second: .pane(directory: nil)))
        SessionRestore.save([state])
        #expect(SessionRestore.load() == [state])
        SessionRestore.clear()
        #expect(SessionRestore.load().isEmpty)
    }

    // MARK: - Versioning (B09)

    @Test("a freshly constructed state carries the current version")
    func newStateCarriesCurrentVersion() {
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: nil))
        #expect(state.version == WindowState.currentVersion)
    }

    @Test("state saved with no version field reads as version 0")
    func missingVersionFieldReadsAsZero() throws {
        let json = Data(
            #"""
            {"frame": {"x": 0, "y": 0, "width": 900, "height": 560},
             "layout": {"pane": {"directory": null}}}
            """#.utf8)
        let state = try JSONDecoder().decode(WindowState.self, from: json)
        #expect(state.version == 0)
    }

    @Test("a window saved by a future, unrecognized version is skipped on load")
    func futureVersionIsSkippedNotCrashed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = Data(
            #"""
            [{"version": 999, "frame": {"x": 0, "y": 0, "width": 900, "height": 560},
              "layout": {"pane": {"directory": null}}, "isSelectedTab": true}]
            """#.utf8)
        try json.write(to: SessionRestore.fileURL)
        #expect(SessionRestore.load().isEmpty)
    }

    // MARK: - Tab group (B09)

    @Test("tab group fields round-trip through the state file")
    func tabGroupFieldsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: nil), tabGroupID: "group-1", tabIndex: 1,
            isSelectedTab: false)
        SessionRestore.save([state])
        let loaded = try #require(SessionRestore.load().first)
        #expect(loaded.tabGroupID == "group-1")
        #expect(loaded.tabIndex == 1)
        #expect(!loaded.isSelectedTab)
    }

    @Test("state saved before tab grouping existed defaults to selected, ungrouped")
    func missingTabFieldsDefaultToSelectedUngrouped() throws {
        let json = Data(
            #"""
            {"frame": {"x": 0, "y": 0, "width": 900, "height": 560},
             "layout": {"pane": {"directory": null}}}
            """#.utf8)
        let state = try JSONDecoder().decode(WindowState.self, from: json)
        #expect(state.tabGroupID == nil)
        #expect(state.tabIndex == nil)
        #expect(state.isSelectedTab)
    }
}

/// U07 — the crash path, staged.
///
/// A test cannot kill the app mid-restore, but it does not need to: what a
/// crash leaves behind is a marker file next to the state, and that is the
/// input the next launch reads. Both halves are exercised here against a real
/// state directory — the launch after a crash *during* a restore, and the
/// launch after a crash at any other time, which must still find its windows.
@MainActor
@Suite(.serialized, .sessionRestoreSerialized)
struct RestoreCrashRecoveryTests {
    private func withTemporaryStateDirectory(_ body: () throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-crash-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }
        try body()
    }

    private var state: WindowState {
        WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: nil))
    }

    /// **A crash during a restore.** The marker is still there, so the layout
    /// that was being applied is the suspect and is not applied again.
    @Test func aLaunchAfterACrashDuringRestoreStartsFresh() throws {
        try withTemporaryStateDirectory {
            SessionRestore.save([state])
            SessionRestore.beginRestore()  // and then the process dies here
            #expect(SessionRestore.decideRestore() == .skipAfterFailure)
        }
    }

    /// **A crash at any other time.** No marker, and the debounced write left
    /// the arrangement on disk — which is the case the whole feature exists
    /// for and the one the old delete-at-launch made impossible.
    @Test func aLaunchAfterACrashElsewhereRestores() throws {
        try withTemporaryStateDirectory {
            SessionRestore.save([state])
            SessionRestore.beginRestore()
            SessionRestore.endRestore()  // the restore finished; later, a crash
            #expect(SessionRestore.decideRestore() == .restore([state]))
        }
    }

    /// A clean first run.
    @Test func nothingSavedMeansNothingToRestore() throws {
        try withTemporaryStateDirectory {
            #expect(SessionRestore.decideRestore() == .nothingToRestore)
        }
    }

    /// The skip is once, not forever: the next launch after it restores
    /// normally, because the marker was cleared on the way past.
    @Test func theSkipHappensOnce() throws {
        try withTemporaryStateDirectory {
            SessionRestore.save([state])
            SessionRestore.beginRestore()
            #expect(SessionRestore.decideRestore() == .skipAfterFailure)
            // What the app does on that branch.
            SessionRestore.clear()
            SessionRestore.endRestore()
            #expect(SessionRestore.decideRestore() == .nothingToRestore)

            SessionRestore.save([state])
            #expect(SessionRestore.decideRestore() == .restore([state]))
        }
    }
}
