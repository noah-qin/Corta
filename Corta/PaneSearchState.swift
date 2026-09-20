import AppKit
import CortaTerminal

/// Search UI, task lifetime and scroll anchors belonging to one terminal pane.
@MainActor
final class PaneSearchState {
    var bar: NSGlassEffectView?
    var container: NSGlassEffectContainerView?
    var field: NSTextField?
    var matches: [SelectionRange] = []
    var currentMatchIndex: Int?

    /// Absolute row (totalPushed + row), stable while output scrolls.
    var currentMatchAnchor: Int?

    var status: SweepOutcome.Status = .complete
    var matchesTruncated = false
    var task: Task<Void, Never>?
    /// Paired scroll position and scrollback anchor, restored when search closes.
    var previousScrollOffset: Int?
    var previousTotalPushed: Int?
    /// Reject results from superseded sweeps; retain output arriving during a sweep.
    var generation = 0
    var needsRefresh = false
    /// Optional test barrier for deterministic background-sweep races.
    var sweepGate: (@Sendable () -> Void)?
    var caseSensitive = false
    var regex = false
    var keyMonitor: Any?

    struct SweepOutcome: Sendable {
        var matches: [SelectionRange]
        var status: Status

        enum Status: Sendable {
            /// The whole document was searched.
            case complete
            /// The sweep hit the match cap, a line too long to run a pattern
            /// against, or its time budget. The count is a floor.
            case incomplete
            /// The pattern does not compile.
            case invalidPattern
            /// The pattern's shape makes a backtracking engine take
            /// exponential time, so it was refused before it ran (U16).
            case patternTooSlow
        }
    }
}
