# Releasing Corta

[Documentation index](README.md) · [Contributing](../CONTRIBUTING.md)

The steps the maintainer takes to cut a release. The rules a release must
satisfy are enforced by `corta-release-check`, the one implementation
of them; this page is the order of operations around it. Decision D20
(`DECISIONS.md`) explains why the update feed is signed from CI.

## Release checklist

For the maintainer, cutting any release:

1. Move the relevant `[Unreleased]` entries under a new `## [x.y.z]`
   heading with the date, and leave `[Unreleased]` empty above it. At the
   bottom of `CHANGELOG.md`, point `[Unreleased]` at `vx.y.z...main` and
   add an `[x.y.z]` link to the new tag.
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
   commit — `corta-release-check` verifies that name at the tag, so
   it cannot wait for publication.
4. Commit as `chore: release x.y.z`, then tag `vx.y.z` and push the tag.
   The release workflow builds from the tag and opens a **draft** release
   for review — it is never published automatically. The run waits for
   the maintainer's approval first (**Review deployments** → `release` →
   **Approve and deploy**): it runs in the `release` environment because
   it can reach the signing key (below).
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
   The workflow is the only route that signs the feed (D20); if it cannot
   run, fix it and re-run it rather than signing by hand.

## The signing key

`release.yml` signs and notarises with one App Store Connect API key and
nothing else: no certificate, no `.p12`, no keychain on the runner.
`xcodebuild -exportArchive -allowProvisioningUpdates` signs with the
team's cloud-managed Developer ID certificate, whose private key stays
with Apple, and `notarytool` authenticates with the same key. The key
lives in the `release` GitHub environment, beside the Sparkle key, and
no copy is kept anywhere else — a lost key is replaced, not restored:

| Name            | Kind                 | Value                                   |
| --------------- | -------------------- | --------------------------------------- |
| `ASC_KEY`       | environment secret   | the `.p8` file, as downloaded           |
| `ASC_KEY_ID`    | environment variable | its Key ID                              |
| `ASC_ISSUER_ID` | environment variable | the team's Issuer ID                    |

Without all three the workflow produces an ad-hoc build and its release
notes say so; that is also what a fork gets.

**Rotating the key**, when it may have leaked or once a year:

1. In App Store Connect, **Users and Access → Integrations → Team Keys**,
   generate a key with the **Admin** role. Cloud-managed Developer ID
   signing needs Admin; the Account Holder may also have to allow access
   to cloud-managed Developer ID certificates.
2. Store it without letting it touch the command line, then delete the
   download:

   ```sh
   gh secret set ASC_KEY --env release < AuthKey_KEYID.p8
   gh variable set ASC_KEY_ID --env release --body KEYID
   rm AuthKey_KEYID.p8
   ```

   `ASC_ISSUER_ID` only changes if the team does.
3. Rehearse (below). Once it passes, **Revoke** the old key in App Store
   Connect.

Revoking the key stops nothing that already shipped. Revoking a
Developer ID *certificate* is a different matter — Gatekeeper can then
refuse software signed with it — so an old certificate is left to expire.
A new certificate from the same team satisfies the designated requirement
of every earlier build, so Sparkle updates and the user's privacy grants
carry over.

**Rehearsing** a signing change without a release:

```sh
gh workflow run release.yml --ref <branch> -f dry_run=true
```

A dry run builds the ref at the version the project carries, signs,
notarises and runs `corta-release-check --require-notarized`, then keeps
the archive as a workflow artifact for a week instead of drafting a
release. The `release` environment only admits `v*` tags, so add the
branch to its deployment policy for the rehearsal and remove it after,
as for `appcast.yml`'s dry run.
