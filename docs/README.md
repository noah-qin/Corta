# Corta documentation

Two kinds of document live here, kept apart on purpose. The **durable**
documents describe Corta as it is — what a setting does, why a decision
was made, how a subsystem is built — and are edited whenever the code
changes. The **record** under `history/` describes how it got here and is
not edited except to fix a link. When the two disagree, the durable
document is right and the record is a record.

## For users

| Document | Read it when |
| :--- | :--- |
| [`CONFIGURATION.md`](CONFIGURATION.md) | You want to change a setting, define a theme, rebind a key, add a preset, or find out when a change takes effect. Every key in `~/.config/corta/config`, in one table each. |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | Corta will not install, will not start, or does something your last terminal did not. Ends with how to uninstall cleanly. |
| [`../CHANGELOG.md`](../CHANGELOG.md) | You want to know what changed in a release, or what has landed on `main` since the last one. |

## For contributors

| Document | Covers |
| :--- | :--- |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | Commit convention, branches, pull requests, what a change must carry. Start here. |
| [`DECISIONS.md`](DECISIONS.md) | The settled decisions, one record each: what, why, and what reopening costs. Read before proposing an architecture change. |
| [`DESIGN.md`](DESIGN.md) | Goals, the architecture, every module and its boundaries, the non-goals. |
| [`CONFORMANCE.md`](CONFORMANCE.md) | Feature priorities (P0/P1/P2), the daily-driver checklist, the test strategy — esctest, the fuzz harness, and the five-point manual check every app-layer change gets. |
| [`PERFORMANCE.md`](PERFORMANCE.md) | Targets, the hot-path rules, how each number is measured, and the numbers. |
| [`SECURITY.md`](SECURITY.md) | The threat model, escape-sequence injection, resource caps, process safety, the three trust boundaries, and a change log of every security-relevant change. |

The public core API is documented in place: `CortaTerminal/Sources/
CortaTerminal/CortaTerminal.docc` holds the landing page and one article
on the pipeline, and `xcodebuild docbuild -scheme CortaTerminal` (or
Product ▸ Build Documentation in Xcode) renders it with the symbol
documentation. Generated documentation is not a goal in itself; the
catalog exists so that a contributor can find where a byte goes.

## The record

| Document | What it is |
| :--- | :--- |
| [`history/ROADMAP-0.1.md`](history/ROADMAP-0.1.md) | The M1–M10 step-by-step plan that produced 0.1.0, with every box ticked and every measurement recorded where it was taken. |
| [`history/V0.1.1-QUALITY-PLAN.md`](history/V0.1.1-QUALITY-PLAN.md) | The 0.1.1 quality release's working notes: every finding, what was done about it, and what was left. |
| [`history/V0.1.1-ENGINEERING-AUDIT.md`](history/V0.1.1-ENGINEERING-AUDIT.md) | The engineering audit that fed the quality plan. |
| [`history/V0.1.1-MANUAL-VERIFICATION.md`](history/V0.1.1-MANUAL-VERIFICATION.md) | What a person checked by hand for 0.1.1, and what was marked *not judged*. |
| [`history/V0.1.1-UI-WALKTHROUGH.md`](history/V0.1.1-UI-WALKTHROUGH.md) | The native-behaviour walkthrough. |
| [`history/TECHNOLOGY-DIRECTION.md`](history/TECHNOLOGY-DIRECTION.md) | The technology candidates considered between 0.1.1 and the v1 roadmap; the ones adopted are B-series issues. |
| [`esctest/`](esctest/) | esctest result files per release. |

The active plan is not a document here: it is the sixteen ordered
`B01`–`B16` issues under the
[v1.0.0 milestone](https://github.com/noah-qin/Corta/milestone/1). Each
issue owns its scope, dependencies and acceptance criteria; the documents
above hold what those issues decided that has to outlive them.
