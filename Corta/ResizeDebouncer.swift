import CortaTerminal
import Foundation

/// Coalesces resize events so a live window drag does not hammer the child
/// with `TIOCSWINSZ` — and the resulting `SIGWINCH` — at every mouse motion
/// (ROADMAP.md M2.9, CONFORMANCE.md §2.3). Events within the debounce window
/// collapse to the latest size; the final size is always delivered, either
/// when the window goes quiet or immediately via `flush()` at the end of the
/// drag.
///
/// Main-actor isolated: window layout callbacks all arrive on the main
/// thread, and the timer fires on the main queue.
@MainActor
final class ResizeDebouncer {
    private let delay: TimeInterval
    private let handler: (TerminalSize) -> Void
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval = 0.1, handler: @escaping (TerminalSize) -> Void) {
        self.delay = delay
        self.handler = handler
    }

    /// Records a new size. With `coalesce` false (initial layout,
    /// programmatic resizes) the size is delivered synchronously; with
    /// `coalesce` true (a live drag) it replaces any pending size and is
    /// delivered once the stream of events stops for `delay` seconds.
    func resize(to size: TerminalSize, coalesce: Bool) {
        pending?.cancel()
        pending = nil
        guard coalesce else {
            handler(size)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.handler(size)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Delivers any pending size now — call when the live resize ends so the
    /// child sees the final size without waiting out the debounce window.
    func flush() {
        guard let item = pending, !item.isCancelled else { return }
        pending = nil
        // Perform *before* cancelling: a work item runs at most once, so the
        // scheduled fire is then a no-op — but `perform()` on an
        // already-cancelled item does nothing, so the order matters.
        item.perform()
        item.cancel()
    }
}
