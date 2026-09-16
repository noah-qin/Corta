## What this changes

<!-- One paragraph. What behaviour is different after this PR, and why. -->

## Why

<!-- The reason, not the diff. If it fixes an issue, write "Fixes #123". -->

## Checklist

- [ ] The commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), in English, subject ≤ 72 characters (`CONTRIBUTING.md`).
- [ ] `xcodebuild -project Corta.xcodeproj -scheme Corta test` passes.
- [ ] `swift test --package-path CortaTerminal` passes.
- [ ] This does not reopen a decision in `docs/DECISIONS.md`, or if it does, the PR edits that entry and says what the concrete new reason is.
- [ ] Every user-visible change has an entry under `CHANGELOG.md` `[Unreleased]`.
- [ ] A new or changed config key has its row in `docs/CONFIGURATION.md` §2 and, if it applies at a particular moment, §7.
- [ ] A new user-facing string is in `Localizable.xcstrings` for all nine locales, non-English ones marked `needs_review` (`CONTRIBUTING.md` › Localization).
- [ ] What was **not** verified — human-only checks, hardware you do not have, remote hosts — is listed below rather than left implied.

## Not verified

<!-- List it. "Multi-display focus return was not tested; I have one display." An honest gap is a note for the reviewer, not a mark against the PR. -->

### If this touches the AppKit shell, the renderer or the window

- [ ] **Verified by launching the app**, not only by tests — `docs/CONFORMANCE.md` §4.4. Offscreen render tests cannot see view-hierarchy, orientation, startup-ordering or gesture defects.

### If this touches the render loop or the hot path

- [ ] **The frame-CPU baseline was re-measured** and is reported below. `docs/PERFORMANCE.md` has the method.

```
frame CPU before:
frame CPU after:
```

### If this touches packaging, versions or the release workflow

- [ ] `scripts/check-release.sh` still passes against a built app, and any new rule was added there — not in `package-release.sh`, `release.sh` or `release.yml`, which only call it.

### If this touches the parser, the grid or anything reading PTY bytes

- [ ] The fuzz corpus still replays clean: `corta-fuzz --fuzz 500000 --seed 1 CortaTerminal/Tests/Fuzz/corpus`.
- [ ] No byte derived from terminal output is written back to the child's stdin (`docs/SECURITY.md` §6).
