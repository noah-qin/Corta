# Technology direction — modern native macOS first

The active [B01–B16 GitHub roadmap](https://github.com/noah-qin/Corta/milestone/1),
recorded 2026-09-10, includes intelligent navigation, SSH/SFTP, current
macOS/Swift UI work and a real Metal 4 backend. Built-in AI is excluded;
existing AI CLI compatibility is retained. Roadmap entries do not change the
current release's capabilities or minimum deployment target.

Maintainer preference recorded 2026-09-05: actively adopt the newest macOS,
Swift, Xcode and Metal capabilities. Prefer a modern implementation over
retaining an older implementation merely because it already works. This is
an explicit product/engineering direction, not a claim that every new API is
automatically faster or that an experiment is already shipped.

## How future work should follow this preference

1. At implementation time, check current Apple/Swift primary documentation,
   installed SDK declarations, release status and hardware requirements.
   Previously recorded version numbers are historical observations, not a
   permanent definition of "latest".
2. Prefer the newest suitable public API and current supported language
   features. Actively prototype meaningful preview capabilities instead of
   deferring all adoption until a later major release.
3. Use the latest verified stable toolchain for the main development/release
   lane, pinned to an exact version for reproducibility. Maintain a separate
   latest-preview compatibility lane and advance the pinned lane deliberately.
4. For preview SDK/OS features, record availability, test hardware/OS and the
   fallback or deployment-target consequence. The preference welcomes these
   experiments; it does not itself change the current deployment target or
   install a beta operating system on the maintainer's machine.
5. Implement the new capability for real. A forwarding wrapper, feature flag,
   protocol conformance or supported-family check alone is not adoption.
6. Record behaviour, latency, memory, energy and failure-mode evidence. New
   technology is a reason to explore and implement, not a substitute for
   correctness or permission to claim an unmeasured performance improvement.
7. Keep compatibility code only for an explicit supported OS/hardware/test
   need. Record its removal condition; avoid indefinite parallel paths with no
   owner. A mature public API remains appropriate if no newer API fits the
   terminal's requirements.
8. Preserve the native macOS focus, Swift core, security boundaries and
   terminal correctness. The v1 roadmap accepts remote workflows outside the
   terminal core and excludes built-in AI. Remote features need concrete
   capability, resource and authorization boundaries; this does not implicitly
   add cloud sync, a built-in multiplexer or arbitrary remote command execution.

## Active modernization work

- [ ] N01 **Metal 4**: Implement a real command submission/encoding path for
  supported hardware, including resource lifetime, synchronization and shader
  interfaces. Replace the current pass-through experiment. Compare identical
  workloads with the existing renderer; choose default activation using both
  the maintainer's adoption preference and measured correctness/resource cost.
- [ ] N02 **Swift systems APIs**: Extend appropriate use of InlineArray and
  evaluate Span and strict memory-safety checking around parser/buffer
  boundaries. Keep allocations, bounds and lifetime semantics explicit.
- [ ] N03 **Swift concurrency**: Replace avoidable unchecked shared state with
  explicit ownership/synchronization; use suitable modern execution annotations
  and cancellation for search/decode. Keep blocking PTY work off the cooperative
  executor. Modernization must resolve the callback-startup race.
- [ ] N04 **Swift Testing**: Adopt isolated exit tests, parameterized adversarial
  cases and image/log attachments where they improve regression diagnosis.
  Evaluate specialization/inlining only at measured hot spots.
- [ ] N05 **New AppKit input/selection APIs**: Prototype gesture/control-event
  integration and NSTextSelectionManager on a supporting SDK/OS. Adapt them to
  terminal-owned grid/wrap/history semantics rather than replacing those rules
  with ordinary editable-text assumptions. Preserve TUI mouse mode and IME.
- [ ] N06 **Latest native appearance**: Adopt appropriate interactive glass,
  concentric corners, focus/key-view-loop and accessibility improvements. Use
  availability checks where necessary; keep reduced motion/transparency and
  text contrast correct. Glass belongs on useful controls and surfaces.
- [ ] N07 **Clipboard and secure input**: Integrate current pasteboard privacy
  behaviour and Secure Keyboard Entry, including explicit user intent, visible
  state and balanced focus/close/quit handling.
- [ ] N08 **System integration**: Design Quick Terminal and narrowly scoped
  AppleScript/App Intents for window/pane opening and focus; evaluate safe
  terminal light/dark-mode notification support. Keep external automation and
  untrusted terminal output as separate trust boundaries.
- [ ] N09 **Modern restoration and termination**: Evaluate current AppKit
  restoration APIs alongside existing layout storage; improve Space/fullscreen/
  focus restoration and nonessential modal handling without losing live jobs
  or pretending to resurrect terminated processes.
- [ ] N10 **Toolchain/API maintenance**: Add stable/preview SDK lanes, review
  compiler deprecation diagnostics, and document each retained legacy path's
  reason. Distinguish language mode, package tools version, compiler version,
  SDK version and runtime deployment target.

For each item, record the chosen API, required versions/hardware, implemented
behaviour, tests, benchmark where relevant, fallback/removal condition and
whether it is experimental, enabled by default or shipped. Do not mark an
item complete after only adding a scaffold.

## Relationship to the 0.1.1 work

All earlier accepted work remains tracked in
[V0.1.1-QUALITY-PLAN.md](V0.1.1-QUALITY-PLAN.md), with detailed follow-up in
[V0.1.1-ENGINEERING-AUDIT.md](V0.1.1-ENGINEERING-AUDIT.md).
This direction updates the earlier conservative adoption recommendation:
modern implementations are active work, not automatically relegated to an
unspecified later release. Fix severe safety/lifecycle defects first; pursue
modernization in the affected components as implementation proceeds. Explicitly
report remaining items at a release cut instead of silently dropping them.

## Review coverage and retained requirements

The three documents collectively retain the requests from all review rounds:

| Area | Tracking |
| --- | --- |
| Protocol crashes, clipboard/Services/drop safety, URLs, resource limits | S01–S08 |
| PTY writes/locks/resize/search/images, Unicode caches, launch/energy/soak | P01–P11 |
| IME/AX/keyboard/mouse/config/restore, real TUI workflows | U01–U10 |
| Clear/reset, search controls/regex, scroll feedback, pane zoom | U11–U13, U16 |
| Command-output copy/navigation, reopen layout, export, presets, links/fonts | U14–U18 |
| Compatibility reporting, docs, GUI/CI/release/competitor evidence | Q01–Q08 |
| Whole-window teardown, callback races, read/spawn bounds, reentrancy | E01–E05 |
| Benchmark timeout accounting and actual Metal 4 implementation | E06–E07, N01 |
| Menu grouping, contextual actions, real Help, localization and shortcuts | M01–M06 |
| Secure entry, quick terminal, automation, appearance notifications | M07–M08, N07–N08 |
| Modern APIs, actor boundaries, Swift Testing, OS availability | A01–A06, N01–N10 |
| Large owners, templates, placeholder/dead-code candidates, stale comments | C01–C05 |
| UI gates, artifacts, fuzz/sanitizers, isolation, caches and release integrity | T01–T11 |

Menu audit should also verify checkmarks and enabled state, native tab/window
actions, one Settings entry, clear screen versus clear history versus reset,
and command palette parity. Touch ID authentication compatibility, denied
pasteboard access, and full-keyboard navigation belong to native-system
acceptance tests; the terminal must not alter system authentication policy.

Same-machine competitor comparisons must identify exact application versions,
font/window/refresh settings, shell/workload, power/thermal conditions and sample
counts. Compare cold/warm launch, typing under load, scrolling, IME, memory and
energy. No overall performance ranking has yet been established.
