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
| [Features](FEATURES.md) | You want an overview of what the development tree does and its known limits. |
| [Configuration](CONFIGURATION.md) | You want to change a setting, define a theme, rebind a key, add a preset, or find out when a change takes effect. Every key in `~/.config/corta/config`, in one table each. |
| [Troubleshooting](TROUBLESHOOTING.md) | Corta will not install, will not start, or does something your last terminal did not. Ends with how to uninstall cleanly. |
| [Changelog](../CHANGELOG.md) | You want to know what changed in a release, or what has landed on `main` since the last one. |

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

The public core API is documented in place:
[`CortaTerminal.docc`](../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)
holds the landing page and one article on the pipeline, and
`xcodebuild docbuild -project Corta.xcodeproj -scheme Corta` (or
Product ▸ Build Documentation in Xcode) renders it with the symbol
documentation. Generated documentation is not a goal in itself; the
catalog exists so that a contributor can find where a byte goes.

The scripts a document tells you to run live in [`scripts/`](../scripts/):
measurement (`measure-*.sh`, `record-signpost-trace.sh`), the real-program
harness (`u10-real-workflows.py`), the isolated developer launch
(the `Corta (Dev)` scheme), the documentation link check (`check-docs.py`), and
packaging (`check-release.sh`, `package-release.sh`, `release.sh`). Each
script's header comment says what it changes and what it never touches.

## The record

| Document | What it is |
| :--- | :--- |
| [0.1 roadmap](history/ROADMAP-0.1.md) | The M1–M10 step-by-step plan that produced 0.1.0, with every box ticked and every measurement recorded where it was taken. |
| [0.1.1 quality plan](history/V0.1.1-QUALITY-PLAN.md) | The 0.1.1 quality release's working notes: every finding, what was done about it, and what was left. |
| [0.1.1 engineering audit](history/V0.1.1-ENGINEERING-AUDIT.md) | The engineering audit that fed the quality plan. |
| [0.1.1 manual verification](history/V0.1.1-MANUAL-VERIFICATION.md) | What a person checked by hand for 0.1.1, and what was marked *not judged*. |
| [0.1.1 UI walkthrough](history/V0.1.1-UI-WALKTHROUGH.md) | The native-behaviour walkthrough. |
| [Technology direction](history/TECHNOLOGY-DIRECTION.md) | The technology candidates considered between 0.1.1 and the v1 roadmap; the ones adopted are B-series issues. |
| [esctest results](esctest/) | esctest result files per release. |
| [Interactive test records](test-results/) | Dated records of interactive test passes — what a person checked, what passed, what failed and what was skipped. The findings are worked off in the CHANGELOG; the record stays as written. |

The completed v1 implementation plan is recorded in the
[v1.0.0 milestone](https://github.com/noah-qin/Corta/milestone/1).
[Open issues](https://github.com/noah-qin/Corta/issues) track follow-up work;
release availability is recorded on [GitHub Releases](https://github.com/noah-qin/Corta/releases).
