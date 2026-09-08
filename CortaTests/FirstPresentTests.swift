import AppKit
import QuartzCore
import Testing

@testable import Corta

/// E05 regression: the first-present flash guard is an explicit state
/// machine (`FrameScheduler.requestFirstPresent` / `notePresentedFrame`),
/// not the old run-loop pump with a swapped-in `onRenderFrame`. These tests
/// pin the two halves of that contract — the stand-in background that covers
/// the transparent window until the first real present, and the absence of
/// any nested run-loop servicing — plus the close/theme/resize orderings
/// that race with the first frame.
@MainActor
@Suite("FirstPresent")
struct FirstPresentTests {
    private static func makeScheduler() -> (FrameScheduler, CAMetalLayer) {
        let layer = CAMetalLayer()
        return (FrameScheduler(metalLayer: layer), layer)
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    /// `DispatchQueue.main.async` closures are `@Sendable`, so a plain
    /// captured `var` won't compile; the flag needs a box.
    private final class Flag: @unchecked Sendable { var value = false }

    @Test func requestArmsStandInBackgroundAndKeepsRenderHandler() {
        let (scheduler, layer) = Self.makeScheduler()
        #expect(scheduler.firstPresentState == .idle)
        #expect(layer.backgroundColor == nil)
        scheduler.onRenderFrame = { _, _, _ in }

        scheduler.requestFirstPresent()

        #expect(scheduler.firstPresentState == .awaitingFrame)
        #expect(layer.backgroundColor != nil)
        // The old implementation wrapped `onRenderFrame` for the duration of
        // the pump; the state machine never touches it.
        #expect(scheduler.onRenderFrame != nil)
    }

    @Test func standInMatchesTheThemeClearColor() {
        let (scheduler, layer) = Self.makeScheduler()
        scheduler.requestFirstPresent()
        let bg = TerminalColorPalette.clearColor
        let expected = CGColor(
            red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w))
        #expect(layer.backgroundColor == expected)
    }

    /// The core E05 regression: `requestFirstPresent` must not run the main
    /// run loop. A block enqueued before the call would have been serviced
    /// *inside* the old `presentSynchronously` pump (its reentrancy); under
    /// the state machine it can only run after this test method returns.
    @Test func requestDoesNotServiceTheMainRunLoop() {
        let (scheduler, _) = Self.makeScheduler()
        scheduler.attach(to: Self.makeWindow())
        defer { scheduler.attach(to: nil) }
        let serviced = Flag()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { serviced.value = true }
        }
        scheduler.requestFirstPresent()
        #expect(!serviced.value)
    }

    /// Theme toggled twice within one vsync: both `drawNow` calls collapse
    /// into one pending first frame, and the single present that eventually
    /// lands retires it exactly once.
    @Test func themeToggleBeforeFirstFrameCollapsesToOneGuard() {
        let (scheduler, layer) = Self.makeScheduler()
        scheduler.requestFirstPresent()
        scheduler.requestFirstPresent()
        #expect(scheduler.firstPresentState == .awaitingFrame)
        #expect(layer.backgroundColor != nil)

        scheduler.notePresentedFrame()
        #expect(scheduler.firstPresentState == .idle)
        #expect(layer.backgroundColor == nil)

        // A further theme change re-arms cleanly from idle.
        scheduler.requestFirstPresent()
        #expect(scheduler.firstPresentState == .awaitingFrame)
        #expect(layer.backgroundColor != nil)
    }

    /// Window closed between the request and the first vsync: the guard
    /// must survive detachment — never strip the stand-in without a real
    /// present — and the first frame after the pane is shown again retires
    /// it.
    @Test func closeBeforeFirstFrameKeepsStandInUntilARealPresent() {
        let (scheduler, layer) = Self.makeScheduler()
        scheduler.attach(to: Self.makeWindow())
        scheduler.requestFirstPresent()
        scheduler.attach(to: nil)
        #expect(scheduler.firstPresentState == .awaitingFrame)
        #expect(layer.backgroundColor != nil)

        scheduler.attach(to: Self.makeWindow())
        defer { scheduler.attach(to: nil) }
        #expect(scheduler.firstPresentState == .awaitingFrame)
        scheduler.notePresentedFrame()
        #expect(scheduler.firstPresentState == .idle)
        #expect(layer.backgroundColor == nil)
    }

    /// A present notification that arrives with nothing armed (every steady-
    /// state frame takes this path) must not disturb the layer.
    @Test func presentWhileIdleIsANoOp() {
        let (scheduler, layer) = Self.makeScheduler()
        scheduler.notePresentedFrame()
        #expect(scheduler.firstPresentState == .idle)
        #expect(layer.backgroundColor == nil)
    }

    /// Resize racing the first frame at the `TerminalView` level: `drawNow`
    /// before and after a bounds change — the guard stays armed throughout
    /// and the drawable tracks the latest bounds, with no window and no
    /// run-loop turn involved.
    @Test func drawNowSurvivesResizeBeforeFirstFrame() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.drawNow()
        view.setBoundsSize(NSSize(width: 400, height: 300))
        view.drawNow()
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.backgroundColor != nil)
        // No window, so the backing scale is 1 and points are pixels.
        #expect(layer.drawableSize == CGSize(width: 400, height: 300))
    }
}
