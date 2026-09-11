/// The document/viewport coordinate conversions duplicated across the
/// render path (`TerminalRenderer`, `KittyImageRenderer`), selection
/// (`Selection.baseScrollbackTotal`), search (`ViewController+Search`),
/// the scrolled-away viewport (`ViewController.scrollAnchorTotalPushed`)
/// and shell-integration prompt-jumping (`ViewController+ShellIntegration`)
/// before B04's follow-up pass — one shared, tested set of primitives
/// instead of the same arithmetic re-derived, independently, at each call
/// site.
///
/// `Scrollback.totalPushed` is the one stable coordinate everything else is
/// measured against: it only grows, unlike `.count` (saturates at the
/// ring's limit) or a raw `scrollOffset` (silently means a different row
/// once the live bottom moves) — see `DESIGN.md` §2.7 and §7 (B04) for the
/// bugs that shape came from.
///
/// **Two sign conventions, both anchored to the same absolute row.** A
/// document row is `totalPushed + relativeRow`, with `relativeRow`
/// negative for scrollback and non-negative for the live screen
/// (`DESIGN.md` §2.7) — that is the convention `Selection`,
/// `ImagePlacementTable` and search matches all store. `scrollOffset` is
/// the mirror image: "lines *above* the bottom," i.e. `-relativeRow`, so a
/// viewport row is `totalPushed - scrollOffset`. Re-anchoring the first
/// kind subtracts the scrollback's growth to stay at the same absolute
/// row; re-anchoring the second kind adds it. Both are exposed below,
/// named for which one a caller means, rather than one signed primitive a
/// caller has to remember to negate correctly.
public enum ScrollbackCoordinates {
    /// Re-anchors a document row (`Selection`'s or an image placement's
    /// `baseScrollbackTotal`-relative row, a search match's start row) so
    /// it still names the same absolute position after `totalPushed` has
    /// grown from `oldTotal` to `newTotal`.
    ///
    /// The document only grows forward, so `newTotal < oldTotal` (stale
    /// data, or a reset) shifts by zero rather than going negative.
    @inlinable
    public static func reanchoredRow(_ row: Int, from oldTotal: Int, to newTotal: Int) -> Int {
        row - max(0, newTotal - oldTotal)
    }

    /// Re-anchors a "lines above the bottom" value (`scrollOffset`,
    /// `scrollAnchorTotalPushed`, a paused search's restore offset) so the
    /// viewport still shows the same absolute row after `totalPushed` has
    /// grown from `oldTotal` to `newTotal` — the sign-flipped counterpart
    /// of `reanchoredRow`, for values stored the other way around.
    @inlinable
    public static func reanchoredOffset(_ offset: Int, from oldTotal: Int, to newTotal: Int) -> Int {
        offset + max(0, newTotal - oldTotal)
    }

    /// The document-absolute row a viewport-relative row (a search match,
    /// a shell-integration prompt row from `Grid.absoluteRow`) names, given
    /// the current `totalPushed`.
    @inlinable
    public static func absoluteRow(_ relativeRow: Int, totalPushed: Int) -> Int {
        totalPushed + relativeRow
    }

    /// The document row at the top of the viewport: `scrollOffset` lines
    /// above the live bottom, and the live bottom is `totalPushed` itself.
    @inlinable
    public static func viewportTopRow(totalPushed: Int, scrollOffset: Int) -> Int {
        totalPushed - scrollOffset
    }

    /// The inverse of `viewportTopRow`: the `scrollOffset` that puts a given
    /// document row at the top of the viewport (jumping to a shell-
    /// integration prompt, e.g.).
    @inlinable
    public static func offset(forRow row: Int, totalPushed: Int) -> Int {
        totalPushed - row
    }

    /// The inverse of `absoluteRow`: the viewport-relative row (screen row
    /// if non-negative, scrollback row if negative) a document-absolute row
    /// names, given the current `totalPushed` — converting a command's
    /// absolute output-row range into the document rows `Selection` speaks
    /// in, e.g.
    @inlinable
    public static func relativeRow(_ absoluteRow: Int, totalPushed: Int) -> Int {
        absoluteRow - totalPushed
    }
}
