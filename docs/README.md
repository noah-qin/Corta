# Corta documentation

These documents describe Corta as it is — what a setting does, why a
decision was made, how a subsystem is built, and the numbers that measure
it — and change with the code. How a change was verified lives with the
change: in its pull request, and in the release notes.

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

## For contributors

| Document | Covers |
| :--- | :--- |
| [Contributing](../CONTRIBUTING.md) | Commit convention, branches, pull requests, what a change must carry. Start here. |
| [Testing](TESTING.md) | Local setup, focused suites, golden fixtures, fuzzing and reporting results. |
| [Decisions](DECISIONS.md) | The settled decisions, one record each: what, why, and what reopening costs. Read before proposing an architecture change. |
| [Design](DESIGN.md) | Goals, the architecture, every module and its boundaries, the non-goals. |
| [Conformance](CONFORMANCE.md) | Feature priorities (P0/P1/P2), the daily-driver checklist, the test strategy — esctest, the fuzz harness, and the launched-app check every app-layer change gets. |
| [Performance](PERFORMANCE.md) | Targets, the hot-path rules, how each number is measured, and the numbers. |
| [Security](SECURITY.md) | The threat model, escape-sequence injection, resource caps, process safety and the four trust boundaries. A change's security reasoning lives in its pull request; the earlier S-series log is linked from §8. |
| [Releasing](RELEASING.md) | The maintainer's one-click release pipeline: one manual run on main versions, tests, signs, notarises, publishes and updates the signed feed. |
| [Licensing](LICENSING.md) | The license header every source file carries, which files are covered by `REUSE.toml` instead, and the tool that checks and adds headers. |

The code is documented in place. Four DocC catalogs hold the landing
pages: [`CortaTerminal.docc`](../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)
for the core, with one article on [where a byte goes](../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/Pipeline.md);
[`Corta.docc`](../Corta/Corta.docc/Corta.md) for the app; and one each for
the two helpers the app embeds,
[`corta-exec`](../CortaTerminal/Sources/corta-exec/corta-exec.docc/corta-exec.md) and
[`corta-image-decoder`](../CortaTerminal/Sources/corta-image-decoder/corta-image-decoder.docc/corta-image-decoder.md).
`xcodebuild docbuild -project Corta.xcodeproj -scheme Corta` (or
Product ▸ Build Documentation in Xcode) renders them with the symbol
documentation, without warnings. Generated documentation is not a goal in
itself; the catalogs exist so that a contributor can find where a byte goes.

Tools live in [`scripts/`](../scripts/):

| Task | Tool |
| :--- | :--- |
| Check local Markdown links without building the app | `python3 -B scripts/check-doc-links.py` |
| Select CI checks and extract CodeQL sources | `scripts/ci-docs-only.py`, `scripts/codeql-extract.py` |
| Prepare a release and report automation checks | `scripts/prepare-release.py`, `scripts/prepare-release.sh`, `scripts/report-ci-statuses.sh` |
| Check GPU capability and the signed update feed | `scripts/metal-capability.swift`, `scripts/verify-appcast.swift` |
| Build the development app or verify real SSH/SFTP | `scripts/build-and-run.sh`, `scripts/verify-ssh-integration.py` |
| Render the brand images | `scripts/brand/compose-screenshot.swift`, `scripts/brand/social-preview.swift` |

Python helper tests live in `scripts/tests/`. The release artifact check is
`corta-release-check` in `CortaTerminal` ([packaging](TESTING.md#packaging));
app measurements use `MeasurementUITests` in the `Release` test plan and
`xctrace` ([measuring the app](TESTING.md#measuring-the-app)).

## Earlier records

Dated test passes, benchmark runs and audit notes are not kept in the tree.
Those up to 1.2.0 are preserved, unchanged, at
[this commit](https://github.com/noah-qin/Corta/tree/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs): the
0.1 roadmap and the 0.1.1 audit under `history/`, every release's benchmark
run and check, and the esctest result files. The documents above quote the
figures from them that still matter, with a link to each.

The completed v1 implementation plan is recorded in the
[v1.0.0 milestone](https://github.com/noah-qin/Corta/milestone/1).
[Open issues](https://github.com/noah-qin/Corta/issues) track follow-up work;
release availability is recorded on [GitHub Releases](https://github.com/noah-qin/Corta/releases).
