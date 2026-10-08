# Corta documentation

Two kinds of document live here, kept apart on purpose. The **durable**
documents describe Corta as it is — what a setting does, why a decision
was made, how a subsystem is built — and are edited whenever the code
changes. The **record** under `history/` describes how it got here and is
not edited except to fix a link. When the two disagree, the durable
document is right and the record is a record.

[Project overview](../README.md) · [Contribute](../CONTRIBUTING.md) · [Testing](TESTING.md)

## For users

| Document | Read it when |
| :--- | :--- |
| [User guide](USER-GUIDE.md) | You want to learn every feature, where it lives and how to use it. |
| [Features](FEATURES.md) | You want an overview of what the development tree does and its known limits. |
| [Configuration](CONFIGURATION.md) | You want to change a setting, define a theme, rebind a key, add a preset, or find out when a change takes effect. Every key in `~/.config/corta/config`, in one table each. |
| [Troubleshooting](TROUBLESHOOTING.md) | Corta will not install, will not start, or does something your last terminal did not. Ends with how to uninstall cleanly. |
| [Changelog](../CHANGELOG.md) | You want to know what changed in a release, or what has landed on `main` since the last one. |

Start with the [personalization tutorial](USER-GUIDE.md#personalizing-the-terminal)
for cursor defaults, the optional system bar, host details and graphical themes.
These features arrived in 1.1.5; its changelog section lists them.

## For contributors

| Document | Covers |
| :--- | :--- |
| [Contributing](../CONTRIBUTING.md) | Commit convention, branches, pull requests, what a change must carry. Start here. |
| [Testing](TESTING.md) | Local setup, focused suites, golden fixtures, fuzzing and reporting results. |
| [Decisions](DECISIONS.md) | The settled decisions, one record each: what, why, and what reopening costs. Read before proposing an architecture change. |
| [Design](DESIGN.md) | Goals, the architecture, every module and its boundaries, the non-goals. |
| [Conformance](CONFORMANCE.md) | Feature priorities (P0/P1/P2), the daily-driver checklist, the test strategy — esctest, the fuzz harness, and the five-point manual check every app-layer change gets. |
| [Performance](PERFORMANCE.md) | Targets, the hot-path rules, how each number is measured, and the numbers. |
| [Security](SECURITY.md) | The threat model, escape-sequence injection, resource caps, process safety, the three trust boundaries, and a change log of every security-relevant change. |
| [Releasing](RELEASING.md) | The maintainer's release checklist: versions, tag, draft, publish, and the signed update feed. |
| [Licensing](LICENSING.md) | The license header every source file carries, which files are covered by `REUSE.toml` instead, and the tool that checks and adds headers. |

The public core API is documented in place:
[`CortaTerminal.docc`](../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)
holds the landing page and one article on the pipeline, and
`xcodebuild docbuild -project Corta.xcodeproj -scheme Corta` (or
Product ▸ Build Documentation in Xcode) renders it with the symbol
documentation. Generated documentation is not a goal in itself; the
catalog exists so that a contributor can find where a byte goes.

The scripts a document tells you to run live in [`scripts/`](../scripts/):
the Metal 4 capability probe CI runs (`metal-capability.swift`) and the
update feed's check (`verify-appcast.swift`); each one's header comment
says what it reads and what it never touches. Everything else is Swift
code or a test plan: the release check is `corta-release-check` in
`CortaTerminal` ([testing](TESTING.md#packaging)), and the app's
measurements are `MeasurementUITests` in the `Release` test plan, with
the two `xctrace` recordings beside them
([testing](TESTING.md#measuring-the-app)).

## The record

Dated, and not edited except to fix a link.

- [0.1 roadmap](history/ROADMAP-0.1.md) — the M1–M10 plan that produced 0.1.0, with its measurements.
- [0.1.1 quality plan](history/V0.1.1-QUALITY-PLAN.md) — the 0.1.1 findings and what was done about each.
- [0.1.1 engineering audit](history/V0.1.1-ENGINEERING-AUDIT.md) — the audit that fed the quality plan.
- [0.1.1 manual verification](history/V0.1.1-MANUAL-VERIFICATION.md) — what a person checked by hand for 0.1.1.
- [0.1.1 UI walkthrough](history/V0.1.1-UI-WALKTHROUGH.md) — the native-behaviour walkthrough.
- [Technology direction](history/TECHNOLOGY-DIRECTION.md) — candidates considered before the v1 roadmap.
- [Keypress latency before 1.0.0](history/2026-09-09-LATENCY-BEFORE-1.0.md) — the screen-capture figures and why they do not compare.
- [B01 headless sample, 2026-09-10](history/2026-09-10-B01-HEADLESS-SAMPLE.md) — the first percentile-shaped core numbers.
- [B03 ownership audit, 2026-09-10](history/2026-09-10-B03-OWNERSHIP-AUDIT.md) — how the synchronization table in `DESIGN.md` §7.6 was established.
- [B05 search state, 2026-09-11](history/2026-09-11-B05-SEARCH-STATE.md) — the pane-local search fixes behind `DESIGN.md` §7.7.
- [B06 conformance gaps, 2026-09-11](history/2026-09-11-B06-CONFORMANCE-GAPS.md) — SCOSC/SCORC, OSC 4/5, reverse wraparound, and the measured regression.
- [B11 hot-path pass, 2026-09-13](history/2026-09-13-B11-HOT-PATH-PASS.md) — CPU, locking and memory.
- [B12 render diagnostics, 2026-09-13](history/2026-09-13-B12-RENDER-DIAGNOSTICS.md) — diagnostics and a rejected prewarm.
- [B12 Metal 4 backend, 2026-09-15](history/2026-09-15-B12-METAL4-BACKEND.md) — measured against the MTL3 path.
- [1.0.0 benchmark run, 2026-09-18](history/2026-09-18-V1.0.0-BENCHMARK-RUN.md) — every scenario, including energy.
- [1.0.1 benchmark run, 2026-09-21](history/2026-09-21-V1.0.1-BENCHMARK-RUN.md) — the patch release's re-measurement.
- [1.1.0 benchmark run, 2026-10-03](history/2026-10-03-V1.1.0-BENCHMARK-RUN.md) — the first Release-configuration frame-CPU column, and the search and reflow gains.
- [1.1.1 benchmark run, 2026-10-03](history/2026-10-03-V1.1.1-BENCHMARK-RUN.md) — scripted core measurements for the emergency patch.
- [1.1.1 release checks, 2026-10-03](test-results/2026-10-03-1.1.1-checks.md) — empty-Return regression coverage and launched-app confirmation.
- [1.1.5 benchmark run, 2026-10-07](history/2026-10-07-V1.1.5-BENCHMARK-RUN.md) — scripted core measurements and the Release frame-CPU re-measurement after the render-loop changes.
- [1.1.5 release checks, 2026-10-07](test-results/2026-10-07-1.1.5-checks.md) — suites, fuzz, the esctest re-run and the resize fixes' evidence.
- [1.1.6 release checks, 2026-10-07](test-results/2026-10-07-1.1.6-checks.md) — the rounded-corner patch: render tests, the launched app and a frame-CPU A/B.
- [Local data and hostile-remote audit, 2026-10-08](test-results/2026-10-08-local-data-remote-audit.md) — leak and remote-to-local paths by attacker, the fixes, and the data and entry-point tables.
- [esctest results](esctest/) — result files per release.
- [Interactive test records](test-results/) — dated passes by a person; findings are worked off in the changelog.

The completed v1 implementation plan is recorded in the
[v1.0.0 milestone](https://github.com/noah-qin/Corta/milestone/1).
[Open issues](https://github.com/noah-qin/Corta/issues) track follow-up work;
release availability is recorded on [GitHub Releases](https://github.com/noah-qin/Corta/releases).

The [October 2 follow-up](test-results/2026-10-02-follow-up.md) consolidates
remaining audit work and records the evidence for this round. Historical
reports remain unchanged; current security and testing documents govern.
