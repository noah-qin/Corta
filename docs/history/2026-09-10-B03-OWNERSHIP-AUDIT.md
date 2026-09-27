# B03 ownership and synchronization audit — 2026-09-10

Moved from `DESIGN.md` §7.6 on 2026-09-27 (#117). This is the record as
it was written; `DESIGN.md` keeps the current state of the same topic.


Every mutable-state
owner on the input/output path, and what makes each one safe to touch
from more than one thread:

| Owner | Isolation | Mechanism |
|---|---|---|
| `Parser`, `Performer`, `Grid`, `Scrollback` | `nonisolated` | Pure value types / state machines; mutated only while `TerminalSession.state`'s lock is held. |
| `TerminalSession` | `nonisolated`, `@unchecked Sendable` | `Synchronization.Mutex` around every mutable field (`State`, `Callbacks`, `PendingWrites`, `stopped`, `started`, `requestedResize`). Verified case by case (`docs/history/V0.1.1-ENGINEERING-AUDIT.md` A02); no `@unchecked` is load-bearing on its own. |
| `PTY` | `nonisolated`, `@unchecked Sendable` | Same pattern: a `Mutex<State>` around the exit/reaping/closed flags a descriptor's use depends on (S08). |
| AppKit shell (`ViewController`, `SplitViewController`, `AppDelegate`, `TaskNotifier`) | `@MainActor` (project default) | The Xcode target's `SWIFT_DEFAULT_ACTOR_ISOLATION`; see §2.2 for why the core opts out instead. |

The PTY reader is a dedicated `Thread`, not a `Task` (§2.2, §2.6): it
calls `onOutput`/`onChildExit` directly from that thread, and the shell
is responsible for hopping to `@MainActor` — never the other way
around. Every such hop needs to know two things a bare `[weak self]`
does not tell it: whether the controller is still alive (`weak` answers
that) and whether it is still the controller *for this session*
(`sessionGeneration`, `ViewController.swift`, answers that). A pane can
in principle run `setUpPane()` twice on the same, still-alive instance
(a retry after a failure); `sessionGeneration` is bumped each time and
captured by that session's callbacks at install time, so a callback
from a session a later `setUpPane()` has since replaced is a no-op
instead of mutating state that belongs to a different session. The one
precedent this generalises is older and narrower:
`ViewController+Search`'s `searchRefreshGeneration` guards a detached
background sweep's result the same way, scoped to search alone.

`onChildExit` (`TerminalSession`) is fully built — replay-safe if
installed after the child already exited — but was never installed by
the app before B03, so a child that exited on its own (`exit`, a crash,
`kill`) produced no reaction; `teardown()`'s own `SIGHUP`-driven exit
goes through the identical callback, and `didTeardown` (already the
guard against a second `teardown()`) is what tells the two apart —
`sessionGeneration` alone would not, since a user-initiated close never
installs a new session to bump it for.
