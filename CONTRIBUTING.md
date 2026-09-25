# Contributing to Corta

Thanks for taking the time to contribute! This document describes the
conventions this repository follows. They apply to every contributor —
human or AI assistant.

## Start here

Small, focused contributions are welcome: improve a confusing instruction,
reduce a terminal bug to a byte sequence, review a translation in context,
or add a regression test. For substantial work, discuss the scope on an issue
first so contributors do not duplicate effort.

1. Fork and clone the repository, then create a branch for your change.
2. Install a released Xcode with Swift 6.2 or later on macOS 26.0 or later.
   Only stable Xcode toolchains are supported.
3. Run `swift test --package-path CortaTerminal` for a first core check.
4. Open `Corta.xcodeproj` to work on the app. It resolves Sparkle on the
   first build. For builds without a developer account, use the ad-hoc
   signing flags in [Testing](docs/TESTING.md).
5. Run the checks relevant to the change and open a pull request against
   `main`, including results and anything you could not verify.

## Repository map

| Path | Responsibility |
| :--- | :--- |
| `Corta/` | AppKit shell, input, configuration, fonts and Metal renderer |
| `CortaTerminal/Sources/CortaTerminal/` | Parser, grid, PTY, search and terminal protocols |
| `CortaTerminal/Tests/` | Core tests, golden fixtures and fuzz corpus |
| `CortaTests/`, `CortaUITests/` | App-hosted tests and interactive UI tests |
| `docs/` | User guides, architecture and verification evidence |
| `scripts/`, `.github/` | Measurement, packaging, the isolated developer launch, and continuous integration |

## Tests and documentation

[Testing](docs/TESTING.md) maps each change to its checks. Documentation-only
changes need documentation checks and a rendered review; they do not require
launching the app. App-layer changes do. Changes to the render loop also need
a measured frame-CPU baseline.

Keep public guides in English and use relative links within the repository.
Document defaults, units, prerequisites and limitations alongside examples.
Keep release snapshots dated; do not present planned behaviour as shipped.
Historical records under `docs/history/` retain their original findings.

Use `///` comments for API contracts: units, coordinate systems, ownership,
threading and failure behaviour. Use `//` for a non-obvious implementation
reason or invariant. Avoid narrating the code or using a milestone number as
the only explanation. Test names should describe observable behaviour and
fixture comments should identify the rule being checked.

Before opening a documentation pull request, run the link check:

```sh
python3 scripts/check-docs.py
```

## Developing Corta in Corta

Corta is the terminal its own development happens in. Two applications
make that safe (`docs/DECISIONS.md` D22):

| | Daily driver | Development build |
| --- | --- | --- |
| Bundle | `/Applications/Corta.app` | `CortaDev.app`, from the `Corta (Dev)` scheme |
| Identifier | `dev.noahqin.Corta` | `dev.noahqin.Corta.dev` |
| Configuration | `~/.config/corta/config` | `~/Library/Application Support/Corta Dev/config` |
| State | `~/Library/Application Support/Corta/` | the same stage directory |
| Updater | Sparkle | none |

The daily driver is the installed, signed and notarised **Release**
build — never a build from `main` HEAD. A bug written today should not
be able to eat tomorrow's work, and secure input, the hardened runtime
and Gatekeeper only behave as they do for a user when the build is the
one a user would have. Keep the previous release's `.zip` so a bad daily
driver is one `ditto` away from being rolled back.

Turn *automatic* update installation off on the daily driver. An
automatic update relaunches the application, which takes the session
you are working in with it; leave the check on and pick the moment
yourself.

The fast inner loop is `swift test --package-path CortaTerminal`, which
launches no application at all. App-hosted tests run under the `Unit`
test plan and launch the development build, not the daily driver.
`CortaUITests` — the `UI` test plan — and the flood benchmarks never run
against the daily driver: a UI test drives the keyboard, and a `yes`
flood saturates the pane it runs in. `corta-bench` is headless and is
the right tool for a throughput number.

`SecureInput.disengage()` runs from `applicationWillTerminate`, which a
crash or `kill -9` skips. If a development build dies with Secure
Keyboard Entry engaged, that is the explanation.

## Commit messages

Corta follows [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/).
Every commit message MUST be written in **English**.

### Format

```
<type>(<optional scope>): <description>

<optional body>

<optional footer(s)>
```

### Types

| Type       | When to use it                                                        |
| ---------- | --------------------------------------------------------------------- |
| `feat`     | A new user-facing feature                                             |
| `fix`      | A bug fix                                                             |
| `docs`     | Documentation only                                                    |
| `style`    | Formatting, whitespace, no change in behaviour                        |
| `refactor` | Code change that neither fixes a bug nor adds a feature               |
| `perf`     | A change that improves performance                                    |
| `test`     | Adding or correcting tests                                            |
| `build`    | Build system, Xcode project settings, dependencies, signing           |
| `ci`       | CI configuration and scripts                                          |
| `chore`    | Housekeeping that does not fit above (scaffolding, tooling, cleanup)  |
| `revert`   | Reverts a previous commit                                             |

### Scopes

The scope is optional and names the affected area. Prefer an existing one:

`app`, `ui`, `tests`, `assets`, `project`, `docs`

Example: `fix(ui): keep the window title in sync after a document rename`

### Rules

1. **Subject line**
   - Imperative mood: "add", not "added" or "adds".
   - Lowercase first letter, no trailing period.
   - 72 characters or fewer, including the `type(scope): ` prefix.
   - Describe *what changed*, not the file you touched.
2. **Body** (optional, but expected for anything non-trivial)
   - Separated from the subject by one blank line.
   - Wrapped at 72 characters.
   - Explains *why* the change was made, and any consequence a reviewer
     would not infer from the diff. Bullet lists with `-` are fine.
3. **Footers** (optional)
   - `Refs: #123`, `Closes: #123`, `Co-authored-by: Name <email>`.
   - Breaking changes: append `!` after the type/scope **and** add a
     `BREAKING CHANGE: <explanation>` footer.
4. **One logical change per commit.** Do not mix a refactor with a
   feature, or a dependency bump with a bug fix.
5. No emoji, no ticket ID in the subject line, no `WIP` on `main`.
6. **No tool or session identifiers in a commit message.** No
   `Claude-Session:`, no assistant URLs, no "generated with" footer. This
   repository is public: a session link is a private URL that never stops
   being one, and a commit message is the one place it can never be
   deleted from. It also says nothing a reader of the history needs.

### Examples

```
feat(ui): add a preferences window with a theme picker
```

```
build: adopt Swift 6 and disable the app sandbox

Bump SWIFT_VERSION to 6.0 across all targets so the project builds
under the Swift 6 language mode.

Disable ENABLE_APP_SANDBOX and drop the read-only user-selected files
entitlement; the app needs unrestricted filesystem access during early
development.
```

```
fix!: store window frames per screen instead of globally

BREAKING CHANGE: previously saved window positions are discarded on
first launch after this change.
```

## For AI assistants

Before writing a commit, work through this checklist:

- [ ] Read the staged diff (`git diff --cached`) — describe what it does,
      not what you were asked to do.
- [ ] Pick exactly one `type` from the table above.
- [ ] Subject is English, imperative, lowercase, no period, ≤ 72 chars.
- [ ] Body explains *why*, wrapped at 72 chars, if the change is not
      self-evident.
- [ ] The commit contains one logical change; split it otherwise.
- [ ] Do not add advertising footers, emoji, or co-author trailers unless
      the maintainer asked for them.
- [ ] No tool or session identifiers anywhere in the message (rule 6).
- [ ] Never rewrite published history without explicit instruction.

## Localization

User-facing strings live in `Corta/Localizable.xcstrings`. English is the
source language; the other locales are zh-Hans, zh-Hant, ja, ko, de, fr, es
and pt-BR.

For a new string, provide the English source, preserve format specifiers in
translations, and mark unreviewed non-English entries `needs_review`. This
state is an editorial marker: the translation still ships at runtime.

Prefer a native speaker's review in the running app before marking a
translation `translated`. The zh-Hans catalog is an explicit exception: its
strings were marked `translated` after an assistant review on 2026-09-18,
not a native-speaker sign-off, and strings added since are `needs_review`
until reviewed. That record is in
[the 1.0.0 release checks](docs/test-results/2026-09-18-release-checks.md).
Do not infer native-speaker verification from catalog state alone; describe
the reviewer and scope in the PR, and record any human-only gaps.

## Branches

- `main` is always buildable.
- Work on `<type>/<short-description>`, e.g. `feat/preferences-window`.

## Pull requests

- The PR title follows the same Conventional Commits format as a subject
  line.
- Describe the motivation and how you verified the change.
- Run the applicable checks in [Testing](docs/TESTING.md) before requesting review;
  list skipped or unavailable checks explicitly.
- A template is filled in for you when you open the PR. The three
  conditional sections are not decoration: app-layer changes are verified
  by launching the app, render-loop changes report a re-measured frame-CPU
  baseline, and parser changes replay the fuzz corpus.
- `main` is protected. Changes land by squash merge, and the branch is
  deleted afterwards.

## Reporting problems

- **Bugs and feature requests** — open an issue. The forms ask for the
  byte sequence that reproduces the problem; that is the part that makes a
  VT bug fixable.
- **Could not install or start Corta** — the *Installation blocker* form.
  Check `docs/TROUBLESHOOTING.md` first, and say so if its entry was wrong.
- **Tried Corta and went back** — the *Went back to my old terminal* form.
  No reproduction needed; the reason is the report.
- **Questions and ideas** — Discussions, not issues.
- **Security vulnerabilities** — never in public. `SECURITY.md` has the
  private reporting channel.
- **Conduct** — `CODE_OF_CONDUCT.md`.

## Licence of contributions

Corta is licensed under the Apache License 2.0. Under Section 5 of that
licence, anything you deliberately submit for inclusion is licensed the
same way. There is no separate CLA to sign.

The Corta name, the pangolin mascot and the application icon are not
covered by the source licence — see `NOTICE`.
