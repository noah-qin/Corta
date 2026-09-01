# Corta

A macOS application built with AppKit (Xcode project, Swift 6).

## Layout

- `Corta/` — app target: `AppDelegate.swift`, `ViewController.swift`,
  `Base.lproj/Main.storyboard`, `Assets.xcassets`
- `CortaTests/` — unit tests
- `CortaUITests/` — UI tests
- `Corta.xcodeproj/` — Xcode project; build settings live in
  `project.pbxproj`

## Build & Test

```sh
xcodebuild -project Corta.xcodeproj -scheme Corta build
xcodebuild -project Corta.xcodeproj -scheme Corta test
```

## Commit Messages

**Read `CONTRIBUTING.md` before committing.** Every commit follows
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
and is written in English:

```
<type>(<optional scope>): <description>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`.
Scopes: `app`, `ui`, `tests`, `assets`, `project`, `docs`.

Subject: imperative, lowercase, no trailing period, ≤ 72 characters.
Body: wrapped at 72 characters, explains *why*. One logical change per
commit. No emoji and no advertising footers.

The full rules, examples, and an authoring checklist are in
`CONTRIBUTING.md`.
