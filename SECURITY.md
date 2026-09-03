# Security Policy

A terminal emulator renders **untrusted input with full user privileges**.
Every byte Corta parses may come from a hostile source: a crafted filename,
a malicious repository's `git log`, the output of `curl`, a compromised host
reached over SSH. Reports about that boundary are taken seriously.

This file is the *reporting process*. The threat model and the design rules
that follow from it are in [`docs/SECURITY.md`](docs/SECURITY.md).

## Supported versions

Corta has not had a tagged release yet. Until it does, the supported version
is **the tip of `main`**. Please reproduce against a fresh build of `main`
before reporting.

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion for a security
problem.**

Report it privately through GitHub:

1. Go to the [Security tab](https://github.com/noah-qin/Corta/security)
   of this repository.
2. Choose **Report a vulnerability** to open a private security advisory.

That channel is visible only to the maintainer until an advisory is
published.

### What to include

- The Corta commit you tested.
- The exact byte sequence or input that triggers the problem — a hex dump
  or a `printf` line beats a screenshot.
- What you expected, and what happened instead.
- The impact you believe it has, and why.

### What to expect

This is a single-maintainer project, so please treat these as intentions
rather than a contractual SLA:

| Stage                                   | Target      |
| --------------------------------------- | ----------- |
| Acknowledgement of your report          | 72 hours    |
| An initial assessment of severity       | 7 days      |
| Fix or a documented decision not to fix | 90 days     |

Fixes are disclosed publicly once released. Reporters are credited in the
advisory unless they ask not to be.

## In scope

- **Escape-sequence injection** — anything that causes bytes derived from
  terminal output to be written back to the child's stdin, or that lets
  output forge user input.
- Memory-safety failures, crashes or hangs reachable from PTY output,
  including unbounded resource growth from a crafted stream.
- Clipboard, file-drop, hyperlink and URL-opening paths that escape their
  intended validation — for example a scheme that bypasses the allowlist
  in `docs/SECURITY.md` §2.4.
- Anything that lets terminal output cause execution of a program the user
  did not invoke.
- Config-file parsing failures that a non-local attacker can influence.

## Out of scope

- **Deliberate absences.** Corta does not implement terminal title queries
  or OSC 52 clipboard *reads*, among others. These are refused by design as
  injection vectors (`docs/SECURITY.md` §2.2, §6) and are not missing
  features. A report that Corta "fails" a conformance test for one of
  these is a conformance note, not a vulnerability.
- **The app sandbox being disabled.** This is intentional and documented in
  `docs/SECURITY.md` §4.1: a terminal emulator's entire purpose is to run
  arbitrary user programs with the user's privileges.
- Anything a program the user *chose to run* does with the privileges the
  user *chose to give it*.
- Attacks that require an already-compromised local account, or physical
  access to an unlocked machine.
- Findings from automated scanners with no demonstrated impact.

## The eight rules

`docs/SECURITY.md` §6 states the invariants this project holds itself to.
If you find a code path that breaks one of them, that is worth reporting
even without a full exploit.
