# Releasing Corta

[Documentation index](README.md) · [Contributing](../CONTRIBUTING.md)

Merging code to `main` runs CI without publishing. When ready to ship,
open **Actions → Release → Run workflow**, select **main**, leave `bump`
at `patch` and `dry_run` unchecked, and click **Run workflow**. That single
request starts the complete pipeline; no manual version edit, tag push,
draft review or additional environment approval is needed. Tests,
signatures, notarisation and archive/feed checks still gate delivery.

## One-click releases

1. `Release` checks out the latest `main`, chooses the next patch version
   (for example, `1.1.1` → `1.1.2`) and advances the integer Sparkle build
   number past both the project and the existing feed. Stable ancestor tags
   are compared numerically; prerelease tags do not set the next version.
2. It synchronizes every `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
   in the Xcode project, `CortaVersion.string`, the README download/status
   block and CHANGELOG. Unreleased notes move under the new dated version;
   commit subjects since the previous release are included automatically only
   when Unreleased has no notes.
   Historical installation instructions and older changelog entries stay intact.
3. It opens a version PR, explicitly dispatches the ordinary CI (bot-token
   PR creation does not trigger CI), waits for the matching commit's run,
   and squash-merges only after the branch's required checks allow it.
   GitHub does not count a dispatched run's checks toward a PR, so
   `scripts/report-ci-statuses.sh` copies each CI job's conclusion onto the
   PR's head commit as a status of the same name, linked to the job; a job
   that did not succeed is reported as failed. The feed PR (step 6) does the
   same. Without it the 1.1.5 version PR sat blocked behind green checks.
4. It checks out that exact merge commit, reruns core/app tests, archives
   with the pinned Xcode and Developer ID, exports, packages, notarises,
   staples and checks the app and image with `corta-release-check --require-notarized`.
   Missing signing or Sparkle configuration fails the run; automatic
   releases never fall back to ad-hoc signing.
5. Only after those checks does it create the version tag, upload the DMG
   and SHA-256 sidecar to a temporary draft, and publish it automatically.
   A draft is only an upload staging area, never an approval step.
6. The same pipeline calls `Update feed` as a reusable workflow. It checks
   the published archive, carries over the latest feed from `main`, signs
   the new item with Sparkle, validates it against the app, and opens an
   automatically merged feed PR after CI. The pipeline waits until the
   feed PR has actually merged, so installed users can see the update.

The pipeline is serialized with `cancel-in-progress: false`: an active
release finishes rather than being interrupted during publication. It reads
the latest `main` when preparation starts. Ordinary merges, dependency or
documentation updates, and the generated version/feed commits do not trigger
Release. Only a manual dispatch on this upstream repository's `main` can
prepare a release. GitHub can coalesce multiple pending dispatches, so avoid
clicking Run workflow repeatedly while a release is in progress.

For a deliberate minor or major increment, select `minor` or `major` in the
Run workflow form. The default is `patch`.
A manually chosen higher, not-yet-prepared project version is respected by
the default patch route. Performance measurements and conformance records
are added when measured; the automation does not invent evidence.

## Disk-image packaging (D26)

Release notarises the Developer ID signed app using a temporary ZIP sent
only to Apple, deletes that ZIP and staples the app. It then copies the
app and an Applications symlink into an isolated staging folder, creates
an UDZO read-only image named Corta, signs it with a Developer ID timestamp,
notarises it and staples the image. `corta-release-check package
--require-notarized` checks the finished image and its mounted app and writes
the SHA-256 sidecar. No ZIP is uploaded. Rehearsal package artifacts contain
only `Corta-<version>.dmg` and its `.sha256` sidecar; the source patch and
signed-feed evidence remain separate artifacts.

The feed workflow checks the checksum, mounts read-only with cleanup on
success or failure, and generates/signs from the same DMG with the key on
stdin. `verify-appcast.swift` accepts historical ZIP URLs through 1.1.8
and requires DMG afterwards; nightly verifies the bytes of both formats.
Sparkle 2.9.6 and pinned 2.10.0 support DMG with pre-extraction verification
and a signed feed with zero grace period; neither security setting changes.

After a packaging change merges on main, run the signed/notarised dry run
before requesting a real release. Validate both image and app, checksum,
drag-install and offline first launch on Apple silicon without changing
machine-wide settings. After the first DMG release, test Check for Updates
from the latest ZIP install (1.1.8 at the transition) and a successful
restart. If that transition fails, revert the DMG batch on main and ship a
new ZIP patch; never replace published assets. Enable release immutability
only after these checks pass. Uploads and retries may alter drafts only;
published releases have no asset-mutation path.

## Recovery

A version or feed PR blocked with its CI green is missing those statuses:
check that the job had `statuses: write`, then re-run. As a one-off, closing
and reopening the PR as a maintainer starts an ordinary `pull_request` CI
run instead; reopening cancels its auto-merge, so merge it afterwards.

Re-run the **same Actions run** (failed jobs or all jobs) after a transient CI, signing, upload or
feed failure. The preparation PR is keyed by run ID, so retries reuse its
version and exact merge commit. A published archive is never rebuilt or
replaced; a retry proceeds to feed verification/publication instead.
A tag that already names another commit is refused. An older failed run
cannot publish after a newer stable tag exists; start a new main run to
release the fix instead. A new dispatch is a new release, not a retry.

The feed workflow can also be dispatched on `main` with `tag=vX.Y.Z` to
repair just the feed. If the feed already carries that version, it verifies
the published bytes and the existing signed item without generating
another PR. A preparation/feed PR left blocked by strict branch checks
stays open; resolve its checks and rerun. Closed unmerged version PRs and
unexpected changes to an existing automation branch fail explicitly.

## One-time GitHub configuration

Configure the `release` environment to keep the existing certificate,
notary and Sparkle secrets. Its deployment policy must admit only the
protected `main` branch; remove the former `v*` tag policy and disable
required reviewers and wait timers. The manual Run workflow request is the
release decision. Workflow edits do not change these GitHub settings.
Signing a main-branch build is an intentional change from D20's
original tag-only, per-run-review policy. `docs/DECISIONS.md` records it.
Other branches and pull request refs are not admitted to this environment.

The repository must permit Actions to create PRs and enable squash and
auto-merge. The main ruleset continues to require `Terminal core (SwiftPM)`
and `App, tests and the update feed`. Both generated PRs run those checks;
the automation does not bypass the ruleset or push directly to `main`.

## Validation

```sh
python3 -B -m unittest discover -s scripts/tests -v
bash -n scripts/prepare-release.sh
```

Validate workflow expressions/dependencies with `actionlint`. An end-to-end
rehearsal, once the workflow is on main, tests/signs/notarises the proposed
next version and retains the source patch and archive without creating a
PR, tag, release or feed change:

```sh
gh workflow run release.yml --ref main -f dry_run=true
```

The rehearsal also runs the pinned `generate_appcast` against the final
stapled archive, using the release environment key through stdin. It
verifies the feed's own signature and the archive's signature with
`verify-appcast.swift`, and keeps `rehearsal-appcast-v<version>` for seven
days. It does not push that feed or publish the archive; the publication
job stays skipped. This exercises `SURequireSignedFeed` before a release
can offer a build that requires it.

## The signing secrets

`release.yml` signs with the Developer ID Application certificate and
notarises with an App Store Connect API key. All of it lives in the
`release` GitHub environment, beside the Sparkle key. Its branch policy
admits only `main` without another review after the manual run request.
No copy is kept anywhere else — a lost secret is replaced,
not restored:

| Name                        | Kind                 | Value                                  |
| --------------------------- | -------------------- | -------------------------------------- |
| `DEVELOPER_ID_P12`          | environment secret   | the Developer ID Application `.p12`, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | environment secret   | its password                           |
| `ASC_KEY`                   | environment secret   | the API key's `.p8`, as downloaded     |
| `ASC_KEY_ID`                | environment variable | its Key ID                             |
| `ASC_ISSUER_ID`             | environment variable | the team's Issuer ID                   |

All five signing values and `SPARKLE_PRIVATE_KEY` must be present. A
missing or empty value fails both real releases and rehearsals rather than
publishing an unsigned build. Check the file before storing it — `base64`
of a nonexistent path prints nothing, and `gh secret set` stores that nothing.

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

**Rehearsing** a signing change uses the dry-run command above on `main`.
It prepares the proposed next version as a patch, signs and notarises it,
runs the ordinary release checks, then retains the archive for a week.
No temporary environment branch exception is needed.

## Platform protection evidence

Before the automation change, GitHub's API on 2026-10-06 confirmed that the
main ruleset required both CI checks and blocked deletion/non-fast-forward
pushes; squash/auto-merge and Actions PR creation were enabled. The release
environment was tag-only and required maintainer review. The automatic
configuration removes that per-run review and replaces the tag policy with
an explicit `main` branch policy, while retaining the environment secrets
and main checks.
Readback on 2026-10-06 confirmed the applied environment has only the `main`
branch policy and no required-reviewer or wait-timer rule.
Platform settings can change independently from this repository; recheck
them when diagnosing a blocked workflow. Never download secret values to
verify their presence.

Sparkle 2.10.0 is pinned to revision
eef1a539a373c1f1a320624b1130fc5de7b2e100. Follow-up source review covered
`SUSignatureVerifier`, `SUUpdateValidator` and their code-signing calls:
missing/invalid Ed25519 signatures are rejected when the installed app has
an Ed25519 key, the downloaded bytes are verified, and update validation
also considers code signing and key changes. This is a scoped source review,
not an exhaustive dependency or cryptographic implementation audit.
