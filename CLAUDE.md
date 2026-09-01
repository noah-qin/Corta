# Corta

A native macOS terminal emulator in pure Swift. Metal rendering, Core
Text shaping, AppKit shell, a hand-written VT parser.

**Status: pre-M1.** The repository currently contains only the Xcode
scaffold. Nothing in `docs/` is implemented yet.

## Documentation

Read the relevant document before making a design decision. They are the
source of truth; this file is an index.

| Document                | Covers                                                     |
| ----------------------- | ---------------------------------------------------------- |
| `docs/DESIGN.md`        | Goals, locked decisions, architecture, modules, milestones, non-goals |
| `docs/CONFORMANCE.md`   | Feature priorities (P0/P1/P2), the daily-driver checklist, test strategy |
| `docs/PERFORMANCE.md`   | Targets, the two decisions that matter, hot-path rules, benchmarks |
| `docs/SECURITY.md`      | Threat model, escape-sequence injection, resource caps, process safety |
| `CONTRIBUTING.md`       | Commit convention, branches, pull requests                 |

## Decisions That Are Settled

Do not reopen these without a concrete new reason. Each is explained in
`docs/DESIGN.md` §2.

- **macOS only.** Metal and Core Text directly, no abstraction layer.
- **Pure Swift, no FFI.** The VT parser is written here, not bound.
- **Lines carry a `wrapped` flag from M1** — reflow, selection and search
  all depend on it. Adding it later means rewriting the grid.
- **The terminal core is not `@MainActor`.** It lives in a local SwiftPM
  package (`CortaTerminal`) with default actor isolation disabled; the
  Xcode project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` applies to
  the AppKit shell only.
- **Cells are fixed-size; complex graphemes spill to a side table.** Rows
  are variable-length.
- **Multi-viewport from day one.** Render into a given rect, never into
  "the window". No singletons in the core.
- **`$TERM` is `xterm-256color`.** A deliberate lie until conformance is
  proven.
- **No multiplexer, no cross-platform, no tmux control mode, no AI
  features, no settings GUI.** See `docs/DESIGN.md` §6.

## Working Rules

**Scope.** M2 (`vim`/`tmux`/`htop` render correctly) is the checkpoint.
Before M2, do not add features, change scope, or refactor architecture.
Ligatures, transparency and the config system are the classic scope
creep here.

**Performance.** The hot path is PTY read → parse → grid write →
instance buffer build. There: `struct` and `ContiguousArray`, raw
`UInt8`/`UInt32` buffers, no per-cell `class`, no `String`, no ObjC
bridging, no per-frame allocation. Outside the hot path, write ordinary
idiomatic Swift — these rules are a targeted exception, not a house
style.

**Security.** Every byte from the PTY is hostile. Never write
attacker-supplied text back to the child's stdin. Some capabilities are
deliberately absent (title query, OSC 52 read) — do not add them as
"missing features". See `docs/SECURITY.md` §6 for the eight-rule summary.

**Testing.** Golden-file grid tests are built during M1, not later:
feed a byte stream, serialise the grid to text, diff against a checked-in
expectation. Record `esctest` pass rate and benchmark numbers at each
milestone.

## Build and Test

```sh
xcodebuild -project Corta.xcodeproj -scheme Corta build
xcodebuild -project Corta.xcodeproj -scheme Corta test
```

Layout:

- `Corta/` — AppKit shell, Metal renderer, font stack
- `CortaTests/`, `CortaUITests/` — test targets
- `Corta.xcodeproj/` — build settings live in `project.pbxproj`
- `docs/` — design documentation

Deployment target is macOS 26.5, Swift 6, app sandbox disabled
(intentionally — `docs/SECURITY.md` §4.1).

## Commit Messages

Full rules in `CONTRIBUTING.md`. In short —
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/),
English:

```
<type>(<optional scope>): <description>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`.
Scopes: `app`, `ui`, `tests`, `assets`, `project`, `docs`.

Subject imperative, lowercase, no trailing period, ≤ 72 characters. Body
wrapped at 72, explains *why*. One logical change per commit. No emoji,
no advertising footers.
