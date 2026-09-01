# Contributing to Corta

Thanks for taking the time to contribute! This document describes the
conventions this repository follows. They apply to every contributor —
human or AI assistant.

## Commit Messages

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

## For AI Assistants

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
- [ ] Never rewrite published history without explicit instruction.

## Branches

- `main` is always buildable.
- Work on `<type>/<short-description>`, e.g. `feat/preferences-window`.

## Pull Requests

- The PR title follows the same Conventional Commits format as a subject
  line.
- Describe the motivation and how you verified the change.
- Make sure `CortaTests` and `CortaUITests` pass before requesting review.
