# Local data and hostile-remote audit

Date: 2026-10-08. A source review of how local secrets could leak and how a
hostile remote end could reach this Mac, beyond command injection and
parsing. Attackers were taken one at a time, each with only what it actually
holds:

| Attacker | Controls | Does not hold |
| --- | --- | --- |
| Hostile terminal output | Bytes printed into a pane (`cat` of a file, a `curl` body, a `git log`) | Any process on the Mac; a user click |
| Hostile SSH/SFTP server | Everything a server sends: names, attributes, contents, errors, OSC sequences in the remote shell | The local account; the user's SSH keys (unless forwarded) |
| Hostile repository or file | Its names and contents, once on disk | Execution until something opens or runs it |
| Another local, unprivileged user | Its own account; world- or `staff`-readable files | The user's `0700` directories, the user's processes |
| A misled user | One click, one Connect, one Retry | — |

An attacker already running code as the user is out of scope
(`SECURITY.md` §1), and was not assumed anywhere below.

**Verification boundary.** The review machine is Linux with no Swift
toolchain: nothing here was compiled, run or launched. Every finding is
from reading the code; the three fixes carry unit tests that have **not been
run**, and none has had the D14 launched-app check. Nothing touched a real
key, token, history or `~/.ssh`.

## Fixed in this change

### F1 — SFTP channel inherited forwarding from `~/.ssh/config`

- **Attacker:** a hostile SSH server (root on it, or a malicious host
  operator), reached through the browser or a ⌘-clicked remote reference.
- **Needs:** the user's configuration to forward for that host (`Host *`
  with `ForwardAgent yes` is common), and one Connect — which the OSC 7
  consent prompt asks for once per run, for a host name the remote chose.
- **Gets:** the user's `ssh-agent` for the life of the connection, so
  signatures with every loaded key toward any host the agent's keys open;
  `RemoteForward` lines expose local ports; `LocalForward` binds local
  ports per connection; `PermitLocalCommand yes` runs `LocalCommand`.
- **Why the old defence fell short:** `SFTPSubprocessChannel.arguments`
  was `-s -- <host> sftp`; nothing turned forwarding off. `sftp(1)` passes
  the same four options this change adds.
- **Fix:** `-oForwardAgent=no -oForwardX11=no -oClearAllForwardings=yes
  -oPermitLocalCommand=no` before `-s` (`SFTPChannel.swift`).
  `SFTPChannelTests.invocationArguments` pins the argv. Authentication with
  the local agent is unaffected; `ProxyJump`/`ProxyCommand` still apply.

### F2 — Retry after Change Host ran on the new host

- **Attacker:** none needed; a misled user, or a network that drops the
  first connection (`.transport` failures are retryable).
- **Path:** upload `secrets.env` to host A → transport failure → Change
  Host → connect to B → Retry on A's row. `SFTPTransferQueue.start` used
  the queue's current `client` (B); the row still said A. A download retry
  likewise wrote B's bytes over the chosen local path.
- **Fix:** each job records its host; `start` refuses a job whose host is
  not the queue's and marks the row failed, not retryable.
  `SFTPTransferQueueLifecycleTests.retryStaysOnItsHost`.

### F3 — Command-history Run executed lines the row did not show

- **Attacker:** hostile output. OSC 133 `A`/`B`/`C`/`D` are accepted from
  any stream, so `cat` of a file can create a record whose "command" is
  several screen lines.
- **Path:** the row draws the first line (`lineLimit(1)`); Run wrote the
  whole text plus Return under bracketed paste, so `make test` on show
  could run `make test` and a second line.
- **Fix:** Run fills a multi-line record instead of running it; the user
  sees all of it at the prompt (`CommandHistoryModel.runsAsShown`).
- **Follow-up (same day):** a single long line tail-truncated in the row
  too (`make test` padded with spaces to a payload). Run now also fills a
  record longer than 80 characters or holding a tab.

## Fixed in the follow-up

Found above as confirmed issues and privacy notes, then fixed on the same
branch at the maintainer's request.

### C1 — A remote stream can set the *local* working directory

`Performer.setWorkingDirectory` accepts an OSC 7 whose host is empty,
`localhost` or this Mac's name as local, from any stream. A remote shell (or
`cat` of a file on it) sending `ESC ] 7 ; file:///Users/<name>/<dir> BEL`
sets `Terminal.workingDirectory`, which S05/S09 describe as local-only by
construction — that construction assumes the remote names its own host.
Consumers: new tabs and splits (spawn `chdir`), session restore
(`state.json`), directory history (`directory-history.json`, only after a
forged OSC 133 `D` with integration), Reveal in Finder, Copy Path, project
root, and local `path:line` resolution.

- **Reach:** a directory that already exists locally (spawn falls back
  otherwise); the username must be guessed. Persisted across restarts via
  restore and history.
- **Impact:** directs the user's next local shells. On its own it reads and
  sends nothing. Combined with a git-aware prompt and a hostile repository
  already on disk at a known path, a new tab's prompt runs `git status`
  there — a known code-execution chain (`core.fsmonitor`); **not
  reproduced**.
- **Also:** a container whose hostname is `localhost` is taken for local.
- **Fix:** `TerminalSession.workingDirectory` returns a report only when
  the kernel puts the shell (the PTY's child) or the foreground job there
  (`PTY.confirmedWorkingDirectory`); otherwise the shell's kernel directory.
  The comparison is on strings with macOS's `/private` folded — a `stat` or
  `realpath` of a path output named could hang on a dead mount. A symlinked
  directory reads as its real path. Gating on `PaneRemoteState` was not
  chosen: it misses a report printed after `ssh` exits, and `cat` locally.
  `WorkingDirectoryConfirmationTests` spawn real shells for both cases.

### C2 — Remote-edit download has no size cap

`RemoteEditCoordinator.materialize` downloads whatever the server sends to
Application Support; a server that omits the size attribute (or claims
terabytes) streams until the disk fills. It needs a ⌘-click and the
once-per-run consent. Unlike the browser there is no progress row or
Cancel. `SFTPSession.read` also accepts a DATA reply longer than the READ
asked for, so a file can end longer than its stated size (no escape: the
offset is the client's).

**Fix:** `SFTPTransferEngine.Configuration.maximumDownloadBytes` refuses a
stated size over the limit before OPEN and ends a transfer whose bytes pass
it; remote editing sets 64 MiB (`RemoteEditCoordinator.maximumCopyBytes`).
Any READ reply longer than asked is a protocol violation.

### C3 — SFTP names are shown unsanitised

`isPlainEntryName` rejects `/`, NUL, `.` and `..` only. Bidi overrides,
newlines and zero-width characters reach the table, conflict sheets and
Finder drags as-is (`invoice\u{202E}fdp.sh` reads as `invoicehs.pdf`).
Downloads are quarantined, which is Gatekeeper's check for an app or
installer; a script opens in its default handler.

**Fix:** `SFTPBrowserModel.displayName` shows controls and
`ConcealingScalars` as U+FFFD in the table, transfer rows, conflict sheets
and remote-edit prompts; `localFileName` saves them as `_` for downloads,
drags, the save panel's suggestion and managed copies. Names inside a folder
download keep the server's spelling (the engine has no `ConcealingScalars`).

### P1 — Remote-edit copies were kept indefinitely

Under `Application Support/Corta/RemoteEdit` (`0700`/`0600`, ACLs cleared)
with no retention limit; a `.env` opened once stayed, and Time Machine
backed it up. **Fix:** `RemoteEditStore.pruneStaleCopies` removes a copy
nobody opened or changed for 30 days whose content still matches its
approved digest; an undecided edit and copies set aside stay.

### P2 — Exports were written `0644`

With the process umask; in a folder other `staff` users can traverse (a
project under a home that is typically `0750`) another account could read a
transcript. **Fix:** `PaneCommands.write` uses `PrivateFile.write` (`0600`,
atomic, `O_EXCL|O_NOFOLLOW`).

## Privacy design, accepted behaviour

- **App Intents** expose window titles to Shortcuts. Titles are the child's
  text; Shortcuts runs as the same user.
- **Accessibility** exposes the grid to clients the user granted; the trace
  logs counts only.
- **Drag staging** in `$TMPDIR/Corta-SFTP-Drag` (`0700`) is removed when the
  browser window closes; a crash leaves it to macOS's `$TMPDIR` cleanup.
- **Consent** is per host *string* for the run: an approval for `prod`
  also covers a later report of `prod` from another pane, which resolves
  through the same `~/.ssh/config` to the same place. Intended.

## Sensitive data → where it goes

| Data | Stored / received at | Who can read it | Protection | Result |
| --- | --- | --- | --- | --- |
| Passwords, passphrases | Never handled by Corta; ssh in a pane reads the tty, the SFTP channel has none | — | SFTP ssh has no tty and fails rather than prompting | No path found |
| SSH private keys, agent | `ssh` / `ssh-agent` only | Remote, if forwarded | F1 turns forwarding off for SFTP; interactive `ssh` stays the user's config | Fixed (F1) |
| Tokens, API keys in output | Grid and scrollback in memory | AX clients the user granted; exports | Never persisted (§5); OSC 52 read absent; notifications carry no text | No leak found; exports `0600` (P2) |
| Command lines | `CommandRecord` in memory; text read from the grid | — | Not persisted; cleared with history | Run spoofing fixed (F3) |
| Environment | Child env via `ChildEnvironment` | Child processes (by design) | `CORTA_*`, `TERM*` stripped; `SSH_AUTH_SOCK` passes to shells | Accepted |
| Clipboard | `NSPasteboard` | Other apps | OSC 52 write off by default and sanitised; read never | No path found |
| Host names, usernames | `recent-hosts.json`, `state.json` | Owner (`0600`, atomic `O_EXCL\|O_NOFOLLOW`) | Clear in Settings; OSC 7 hosts never recorded | OK |
| Local paths | `state.json`, `directory-history.json` | Owner (`0600`) | Restore drops missing directories | Remote paths refused unless the kernel agrees (C1, fixed) |
| Remote file contents | RemoteEdit copies, Approvals, drag staging, chosen download folders | Owner (`0700`/`0600`); backups; admins | Approvals cleared at launch; downloads quarantined, `O_EXCL\|O_NOFOLLOW`, ACL cleared | 30-day retention, 64 MiB cap (P1, C2, fixed) |
| Logs, signposts | Unified log | Admin, sysdiagnose | Only counts and the Debug `CORTA_SFTP_SSH` path are `.public` | No sensitive value logged |
| Release secrets | `release` environment, step env, `RUNNER_TEMP` key (`umask 077`, trap rm) | Workflow steps on `main` | Not in test-step env; artifacts are archives and xcresults | No leak found in workflows read |
| Repository | git | Public | `.gitignore` covers `.p12`, `.env`; no key material in the tree | Clean (`git grep`) |

## Remote entry → local capability → boundary

| Remote entry | Local capability reached | Boundary | Result |
| --- | --- | --- | --- |
| OSC 0/2 title | Window title, notification, App Intent title | Never read back (§2.2) | OK |
| OSC 7, remote host | SFTP host suggestion, remote-edit target | Per-run consent; `SSHDestination` charset; `--` | OK |
| OSC 7, empty/`localhost` host | Local spawn cwd, restore, directory history | Kernel cwd of the shell or foreground job | Fixed (C1) |
| OSC 8 / URL text | `NSWorkspace.open` | http/https/mailto, user click, real target shown | OK |
| `path:line` text, local | Editor via `open-file-command` | Absolute path, no shell, no LaunchServices default | OK |
| `path:line` text, remote | SFTP download + editor | Consent; managed copy; no default handler | 64 MiB cap (C2, fixed) |
| OSC 52 | Pasteboard write | Off by default, sanitised; read absent | OK |
| OSC 133 | Command history Fill/Run | User click; prompt-state gate; multi-line now filled | Fixed (F3) |
| OSC 134 | Directory completion | Display-only labels, fixed key sequences | OK |
| Kitty graphics | Memory | Direct transmission only (no `t=f`/`t=t`/`t=s`), budgets | OK |
| DA/DSR/colour queries | Bytes to stdin | Numeric, fixed-format replies | OK |
| SFTP names | Local paths | One component, UTF-8, symlink components refused, `O_EXCL`, rename-into-place | OK; names shown and saved without concealing scalars (C3, fixed) |
| SFTP types, links | Recursion | Links and specials skipped and reported; depth/entry/byte caps | OK |
| SFTP sizes, mtimes | Conflict decisions, resume | Resume re-validated; digest check before remote-edit upload | Download cap, over-long READ refused (C2, fixed) |
| SFTP contents | Local files | Quarantined; never handed to LaunchServices from remote edit | OK |
| SFTP errors, ssh stderr | Messages | 64 KiB tail; shown as text | OK |
| Upload target | Remote host | Bound to the row's host (F2), to the manifest's host for remote edit | Fixed (F2) |
| App Intents | New window cwd, focus | Existing directory; window by identity; no stdin | Accepted |
| Drag onto pane, Services | Text at prompt | Sanitised, quoted, newline warning | OK |

## Not verified

- No build, no test run, no launched app on this machine (Linux); CI on
  the pull request is the first compile and test run. CI's runner cannot
  render, so the app suites that need a working pane skip there.
- The fsmonitor chain in C1 and the disk-fill in C2 are reasoned, not
  reproduced.
- OpenSSH's handling of the four options was taken from `ssh_config(5)`
  and `sftp`'s own invocation, not run against a server here.
- Editor swap and backup files: Corta uploads only the managed file's
  snapshot, so they are never sent; what an external editor writes beside it
  and how long it keeps it is the editor's.
- Sparkle's own requests beyond the feed URL and EdDSA check were not
  traced.
