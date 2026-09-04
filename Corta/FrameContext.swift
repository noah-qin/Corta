import CortaTerminal

/// The prepared inputs for one frame, computed once by
/// `ViewController.prepareFrame()` (the `FrameScheduler.shouldRenderFrame`
/// callback) and consumed by `ViewController.render(into:...)`
/// (`FrameScheduler.onRenderFrame`), which always runs immediately after it
/// in the same `FrameScheduler.metalDisplayLink` callback — see
/// `FrameScheduler`. Replaces what used to be two independent
/// `session.snapshot()` calls plus two independent `searchMatches.map { ... }`
/// passes per frame with one of each (M9).
struct FrameContext {
    var grid: Grid
    var scrollOffset: Int
    var cursorVisible: Bool
    var selection: TerminalSelection?
    var searchMatches: [TerminalSelection]
    var currentSearchMatchIndex: Int?
    var hoveredLink: TerminalSelection?
}
