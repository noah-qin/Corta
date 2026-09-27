# B05 search state and large-text builds — 2026-09-11

Moved from `DESIGN.md` §7.7 on 2026-09-27 (#117). This is the record as
it was written; `DESIGN.md` keeps the current state of the same topic.


`ViewController+Search.swift`'s query, match list, current-match index
and anchor were already stored per pane — but `search-case-sensitive`
and `search-regex` were read live from `ConfigurationStore` on every
sweep, so toggling either in one pane silently changed what a second,
already-open pane's *next* sweep matched, without that pane's own button
ever updating to say so. Fixed by seeding `searchCaseSensitive`/
`searchRegex` from the config default when a bar opens, using only that
local copy for sweeps and for the button tint, and writing back to
`ConfigurationStore` only as the default for bars opened after this one.

A related gap one level up: `NSEvent.addLocalMonitorForEvents` fires
app-wide, and B02 scoped its Esc handler to the event's own *window* —
but a split puts two panes, each with an open bar, in one window, where
the window check alone can't tell them apart. Fixed by additionally
comparing the window's field-editor delegate against this pane's own
`searchField`.

`scheduleBackgroundSearchRefresh` (M9) drops an output-triggered refresh
request outright when a sweep is already in flight, on the reasoning
that "the next output frame starts a fresh sweep as soon as this one
lands" — true only while output keeps arriving. At the tail of a burst,
nothing else re-triggers a sweep once the render loop pauses, so the
last few lines of a flood could go unsearched until an unrelated
keystroke or scroll happened to nudge it. Fixed with a `searchNeedsRefresh`
flag, set instead of dropped, consumed once the in-flight sweep lands.

`scrollOffsetBeforeSearch`, restored verbatim on close, has the same
drift problem §2.7 documents for a selection: a raw offset does not
track output that arrived while the bar was open. Fixed the one
instance of it (not the general `scrollOffset` anchoring problem, still
open — see B04's item above) by shifting the restore by the growth in
`Scrollback.totalPushed` since the bar opened, the same pattern a
selection's `baseScrollbackTotal` already uses.

Large copy (⌘C/⌘A) and export (⇧⌘S) built their text — `Selection.text`,
O(the range, which for the whole document is O(scrollback)) —
synchronously on the *main actor*, which is the interaction path in this
app (§2.2). Both now run that build on `Task.detached`, a compiler-level
guarantee of leaving the main actor rather than an inference — a plain
`Task {}` created from `@MainActor` code inherits that isolation for its
body, so relying on a nonisolated callee to implicitly escape it again
would be exactly the fragile assumption this fix replaces. A shared
`largeTextTask` handle, generation-guarded together with `didTeardown`,
keeps a superseded build's completion — or the pane's own, from
`teardown()` — from touching state that no longer belongs to it.
`Task.cancel()` here only ever discards a build's result, though: neither
`Selection.text` nor `exportableText` polls cancellation internally (M9's
`Search.find` does), so an in-flight row walk runs to completion off the
main actor regardless of whether it is later applied — see
`ViewController.swift`'s own doc comment on `largeTextTask` for the exact
line this was found and fixed to state accurately, after an earlier draft
of this paragraph overclaimed it. `Data.write(options: .atomic)` already
made the file write itself atomic (`ViewController+Export.swift`, tested
by `ExportWriteTests`) — that half of the issue needed no change.
