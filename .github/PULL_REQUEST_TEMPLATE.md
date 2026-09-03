## What this changes

<!-- One paragraph. What behaviour is different after this PR, and why. -->

## Why

<!-- The reason, not the diff. If it fixes an issue, write "Fixes #123". -->

## Checklist

- [ ] The commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), in English, subject ≤ 72 characters (`CONTRIBUTING.md`).
- [ ] `xcodebuild -project Corta.xcodeproj -scheme Corta test` passes.
- [ ] `swift test --package-path CortaTerminal` passes.
- [ ] This does not reopen a decision settled in `docs/DESIGN.md` §2, or if it does, the PR says what the concrete new reason is.

### If this touches the AppKit shell, the renderer or the window

- [ ] **Verified by launching the app**, not only by tests — `docs/CONFORMANCE.md` §4.4. Offscreen render tests cannot see view-hierarchy, orientation, startup-ordering or gesture defects.

### If this touches the render loop or the hot path

- [ ] **The frame-CPU baseline was re-measured** and is reported below. `docs/PERFORMANCE.md` has the method.

```
frame CPU before:
frame CPU after:
```

### If this touches the parser, the grid or anything reading PTY bytes

- [ ] The fuzz corpus still replays clean: `corta-fuzz --fuzz 500000 --seed 1 CortaTerminal/Tests/Fuzz/corpus`.
- [ ] No byte derived from terminal output is written back to the child's stdin (`docs/SECURITY.md` §6).
