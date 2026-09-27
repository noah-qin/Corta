import CortaTerminal

/// The prepared inputs for one frame, computed once by
/// `ViewController.prepareFrame()` (the `FrameScheduler.shouldRenderFrame`
/// callback) and consumed by `ViewController.render(into:...)`
/// (`FrameScheduler.onRenderFrame`), which always runs immediately after it
/// in the same `FrameScheduler.metalDisplayLink` callback — see
/// `FrameScheduler`. Computing it once means one `session.snapshot()` and
/// one `searchMatches.map { ... }` pass per frame, not one per consumer.
struct FrameContext {
    var grid: Grid
    var scrollOffset: Int
    var cursorVisible: Bool
    var selection: TerminalSelection?
    var searchMatches: [TerminalSelection]
    var currentSearchMatchIndex: Int?
    var hoveredLink: TerminalSelection?
}
