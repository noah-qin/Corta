## Change

<!-- What problem does this solve, and what will a user or contributor observe? -->

## Related issue

<!-- Use "Fixes #123" only if this change fully resolves the issue. -->

## Verification

<!-- List commands and results. For docs, include the link check and rendered review.
     Choose relevant checks from docs/TESTING.md; remove inapplicable rows. -->

| Check | Result |
| :--- | :--- |
| | |

## Limitations / not verified

<!-- State missing hardware, human-only checks, skipped tests or known failures. -->

## Review checklist

- [ ] The scope is focused and the title follows Conventional Commits in English.
- [ ] Documentation and `[Unreleased]` reflect any user-visible change.
- [ ] Relevant checks from `docs/TESTING.md` are recorded above.
- [ ] Existing decisions in `docs/DECISIONS.md` are respected or updated with a reason.

<!-- Keep only the following checks that apply. -->

- [ ] App / input / window changes: launched the app and completed the manual check in `docs/CONFORMANCE.md` §4.4.
- [ ] Renderer / hot path: included comparable before/after frame-CPU measurements.
- [ ] Parser / PTY input: added a focused regression and replayed the fuzz corpus; preserved the trust boundaries in `docs/SECURITY.md`.
- [ ] Configuration: documented keys, defaults and when changes apply.
- [ ] Localization: updated all nine locales and marked unreviewed translations `needs_review`.
- [ ] Packaging: ran `scripts/check-release.sh` against the artifact; kept release rules in that script.
