# Releasing Corta

[Documentation index](README.md) · [Contributing](../CONTRIBUTING.md)

The steps the maintainer takes to cut a release. The rules a release must
satisfy are enforced by `scripts/check-release.sh`, the one implementation
of them; this page is the order of operations around it. Decision D20
(`DECISIONS.md`) explains why the update feed is signed from CI.

## Release checklist

For the maintainer, cutting any release:

1. Move the relevant `[Unreleased]` entries under a new `## [x.y.z]`
   heading with the date, and leave `[Unreleased]` empty above it.
2. Update the three hand-written version numbers, in
   `Corta.xcodeproj/project.pbxproj` (all six build configurations) and
   the core. **Two of them carry the release's semantic version and must
   read exactly the same; the third is a build counter and only has to go
   up:**
   - `MARKETING_VERSION` — the semantic version, e.g. `0.1.1`. What the
     bundle and the About panel show.
   - `CortaVersion.string` in `CortaTerminal/Sources/CortaTerminal/Version.swift`
     — the same string again, and what XTVERSION answers a program with.
   - **`CURRENT_PROJECT_VERSION`** — *not* the semantic version. A plain
     integer that increments once per release (0.1.0 shipped 1, 0.1.1
     ships 2), and the one Sparkle actually compares. Two releases sharing a build number means
     the second is invisible to everyone running the first, and
     `generate_appcast` overwrites the earlier feed entry rather than
     adding one. 0.1.1 hit this: it was built, signed, notarised and
     published carrying build 1, exactly like 0.1.0, and the mistake only
     surfaced at step 5 when the feed came out with one item in it.
   `VersionAgreementTests` fails if the marketing version and the core
   constant disagree, or if the build number is one a 0.1.0 install could
   not be offered.
3. Add the release's column to `docs/PERFORMANCE.md` §5.6 and its full
   run as a dated file under `docs/history/`; record test results in
   `docs/CONFORMANCE.md`. Point the
   README's download instructions at `Corta-x.y.z.zip` in the same
   commit — `scripts/check-release.sh` verifies that name at the tag, so
   it cannot wait for publication.
4. Commit as `chore: release x.y.z`, then tag `vx.y.z` and push the tag.
   The release workflow builds from the tag and opens a **draft** release
   for review — it is never published automatically.
5. Review the draft's archive and **publish** the release. Publishing
   starts the `Update feed` workflow (`.github/workflows/appcast.yml`),
   which pauses for one approval: GitHub notifies the maintainer, and
   the run's page under **Actions** shows **Review deployments** →
   `release` → **Approve and deploy**. The approval is the gate on the
   Sparkle private key (D20): nothing that can push a tag can sign an
   update without a person saying so. An unapproved run waits, then
   expires; nothing is signed or pushed until it is approved. Once
   approved, the workflow signs the archive into `appcast.xml`, checks
   the item against the app, and merges the file to `main` through a
   pull request whose CI it runs and waits for — that is what makes the
   update visible to every already-installed Corta. If the pull request
   is left open, a check failed; the run's log says which. To rehearse or
   re-run: `gh workflow run appcast.yml --ref main -f tag=vX.Y.Z
   -f dry_run=true` (a dry run stops after signing and checking), with
   `main` temporarily allowed in the environment's deployment policy.
   The pull request is opened with the workflow's own token, which the
   repository must allow: Settings › Actions › General › Workflow
   permissions › *Allow GitHub Actions to create and approve pull
   requests*. With it off, the `sign` job still pushes the signed
   `chore/appcast-vX.Y.Z` branch and the `merge` job fails at
   `gh pr create`; opening the pull request from that branch by hand
   is the recovery (1.0.1 shipped that way).
   If the workflow cannot run at all, `scripts/release.sh` against the
   downloaded archive is the manual route to the same file.

[Unreleased]: https://github.com/noah-qin/Corta/compare/v1.0.1...main
[1.0.1]: https://github.com/noah-qin/Corta/releases/tag/v1.0.1
[1.0.0]: https://github.com/noah-qin/Corta/releases/tag/v1.0.0
[0.1.1]: https://github.com/noah-qin/Corta/releases/tag/v0.1.1
[0.1.0]: https://github.com/noah-qin/Corta/releases/tag/v0.1.0
