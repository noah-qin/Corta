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
   update visible to every already-installed Corta. If CI passes while
   GitHub is still refreshing merge eligibility, the workflow enables
   squash auto-merge; the pull request stays open until the requirements
   are satisfied. A failed check leaves it open for review; the run's log
   reports CI failures and the PR merge state. To rehearse or
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

## The signing secrets

`release.yml` signs with the Developer ID Application certificate and
notarises with an App Store Connect API key. All of it lives in the
`release` GitHub environment, beside the Sparkle key, so a run that can
reach it waits for the maintainer's approval and starts only from a `v*`
tag. No copy is kept anywhere else — a lost secret is replaced, not
restored:

| Name                        | Kind                 | Value                                  |
| --------------------------- | -------------------- | -------------------------------------- |
| `DEVELOPER_ID_P12`          | environment secret   | the Developer ID Application `.p12`, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | environment secret   | its password                           |
| `ASC_KEY`                   | environment secret   | the API key's `.p8`, as downloaded     |
| `ASC_KEY_ID`                | environment variable | its Key ID                             |
| `ASC_ISSUER_ID`             | environment variable | the team's Issuer ID                   |

With none of the five — a fork — the workflow produces an ad-hoc build
and its release notes say so. With only some of them it fails and names
the missing ones: an emptied secret reads exactly like a missing one,
and an unsigned draft is not what a tag in this repository should
produce. A dry run fails without all five, since signing is what it
rehearses. Check the file before storing it — `base64` of a path that
does not exist prints nothing, and `gh secret set` stores that nothing.

**Why a certificate and not the key alone.** An App Store Connect API
key cannot sign with the team's cloud-managed Developer ID certificate:
`xcodebuild -exportArchive -allowProvisioningUpdates` with the key fails
with *Cloud signing permission error*, whatever the key's role (#134's
rehearsal, 2026-09-30), and a hosted runner cannot sign in to an Xcode
account instead. So the `.p12` reaches the runner, in a throwaway
keychain that the job deletes.

**Rotating the API key**, when it may have leaked or once a year:

1. In App Store Connect, **Users and Access → Integrations → Team Keys**,
   generate a key. Notarisation needs no more than the Developer role.
2. Store it without letting it touch the command line, then delete the
   download:

   ```sh
   gh secret set ASC_KEY --env release < AuthKey_KEYID.p8
   gh variable set ASC_KEY_ID --env release --body KEYID
   rm AuthKey_KEYID.p8
   ```

   `ASC_ISSUER_ID` only changes if the team does.
3. Rehearse (below). Once it passes, **Revoke** the old key in App Store
   Connect. Revoking a key stops nothing that already shipped.

**Replacing the certificate**, before it expires (the current one runs
to 2031-09-04) or if it may have leaked:

1. As the Account Holder, create a Developer ID Application certificate
   (developer.apple.com → Certificates) and export it with its private
   key from Keychain Access as a `.p12` with a password.
2. Store both, then delete the file and the keychain copy:

   ```sh
   base64 -i Developer-ID.p12 | gh secret set DEVELOPER_ID_P12 --env release
   gh secret set DEVELOPER_ID_P12_PASSWORD --env release   # prompts
   rm Developer-ID.p12
   ```

3. Rehearse. A new certificate from the same team satisfies the
   designated requirement of every earlier build, so Sparkle updates and
   the user's privacy grants carry over. Only a leaked certificate is
   revoked: Gatekeeper can then refuse software signed with it, so an
   old one is otherwise left to expire.

**Rehearsing** a signing change without a release:

```sh
gh workflow run release.yml --ref <branch> -f dry_run=true
```

A dry run builds the ref at the version the project carries, signs,
notarises and runs `corta-release-check package --require-notarized
--rehearsal` — the flag skips only the rule that the feed must not yet
publish the version, since a rehearsal usually rebuilds one it does —
then keeps the archive as a workflow artifact for a week instead of
drafting a release.

The `release` environment only admits `v*` tags, so the branch has to be
added to its deployment policy for the rehearsal. While it is there, a
run from that branch can reach the signing certificate and the Sparkle
key with one approval, and the approval page shows the branch, not the
workflow it runs. Rehearse from a short-lived branch nobody else can push
to, and remove it from the policy as soon as the run finishes.

**Re-running a tag** (a failed draft, say) is a dispatch on the tag
itself — the workflow builds exactly the ref it runs on, and has no input
that could name another:

```sh
gh workflow run release.yml --ref vX.Y.Z
```

It runs the workflow as that tag has it, so a tag cut before a signing
change re-runs with the old signing steps.

## Platform protection evidence

Verified through GitHub's API on 2026-10-02: the active main ruleset requires
`Terminal core (SwiftPM)` and `App, tests and the update feed`, blocks deletion
and non-fast-forward pushes, and has an administrator bypass. The `release`
environment requires maintainer review, permits `v*` tags only, and stores
ASC_KEY, DEVELOPER_ID_P12, DEVELOPER_ID_P12_PASSWORD and SPARKLE_PRIVATE_KEY;
no repository-level Actions secrets were listed. The sole listed collaborator
is the maintainer/admin. Environment administrators may bypass review and
self-review is allowed. These are actual boundaries, not a promise of
independent approval or protection from a compromised maintainer account.
Recheck platform settings before releases because they can change separately
from this repository. Do not expose or download secret values to verify them.

Sparkle 2.10.0 is pinned to revision
eef1a539a373c1f1a320624b1130fc5de7b2e100. Follow-up source review covered
`SUSignatureVerifier`, `SUUpdateValidator` and their code-signing calls:
missing/invalid Ed25519 signatures are rejected when the installed app has
an Ed25519 key, the downloaded bytes are verified, and update validation
also considers code signing and key changes. This is a scoped source review,
not an exhaustive dependency or cryptographic implementation audit.
