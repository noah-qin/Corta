# Crash, concurrency, signing and supply-chain audit

Date: 2026-10-08. The second security review of the day. The
[local-data and hostile-remote audit](2026-10-08-local-data-remote-audit.md)
(S18) is not repeated here. This one covers what that one did not: crashes
and hangs a remote party can trigger, the parts of Swift 6 the compiler does
not check, code signing and where the app is installed, the update and supply
chains, TCC attribution, system-level data exposure, and the escape
sequences Corta does not implement.

Attackers were taken one at a time, each with only what it actually holds:

| Attacker | Controls | Does not hold |
| --- | --- | --- |
| Hostile terminal output | Bytes printed into a pane | Any process on the Mac; a click |
| Hostile SSH/SFTP server | Every frame `sftp-server` would send: lengths, names, attributes, contents, errors | The local account |
| Hostile repository or file | Its names and contents on disk; what `cat` of it prints | Execution until something runs it |
| Another local, unprivileged user | Its own account, world-writable places | The user's `0700` directories and processes |
| A misled user | One click, one Connect, one Shortcut run | — |
| Release-chain attacker | One of: an action tag, a merged edit to `appcast.xml`, the Sparkle package | The `release` environment's secrets |

An attacker already running code as the user is out of scope
(`SECURITY.md` §1) and was not assumed anywhere below.

**Verification boundary.** The review machine is Linux with no Swift
toolchain and no `codesign`/`otool`: no Swift was compiled, no test ran, the
app was not launched, and every new test and fuzz target here is unrun until
CI builds it. Two things were checked against real bytes: the published
`Corta-1.1.8.zip` (SHA-256 `9ec828a7…d4ef`, 6,986,054 bytes, the length the
feed states), whose Mach-O load commands and code-signature blobs were parsed
directly, and Sparkle's published advisories. Everything else is source
reading. What needs a Mac is listed at the end, unrun.

## Summary

No byte sequence was found that stably crashes or hangs a pane. Every
peer-supplied number on the parse paths is clamped, saturated or checked
before it sizes an allocation, forms a `Range` or indexes an array; the one
`precondition` reachable from parsing (`ScreenLines.physicalIndex`) is guarded
by every caller; no `try!`, `as!` or force-unwrap is reachable from peer data.
The previous audits (S06, S12, S14, S16) left the parser in good shape, and
this one confirms it rather than adding to it.

The fixes are to what checks the code, not to the code:

| Commit | Change |
| --- | --- |
| `test: fuzz the osc, kitty and sftp decoders as targets of their own` | `corta-fuzz --target osc|kitty|sftp`, seed corpora, CI and nightly runs, `SFTPFuzzCorpusTests` |
| `ci: pin ci and nightly actions by commit and drop the token` | `actions/checkout`, `upload-artifact` by commit in `ci.yml`/`nightly.yml`; `persist-credentials: false` |
| `build: hold every signed component to the hardened runtime rules` | `corta-release-check`: denied entitlements, hardened runtime, one team, load paths |
| `fix(app): declare the file-timestamp reasons in the privacy manifest` | `PrivacyInfo.xcprivacy` said less than the app does |
| `ci: refuse feed items that say more than the signature covers` | `verify-appcast.swift` allowlists item fields |

## 1 · Actual vulnerabilities

None in the shipped app. Three gaps in the release chain were closed.

### V1 — CI ran actions by mutable tag

- **Attacker:** whoever can move the `v7` tag of `actions/checkout` or
  `actions/upload-artifact` (the action's maintainers, or a compromise of
  them).
- **Gets:** code execution in every `ci.yml` and `nightly.yml` job — every
  pull request, every push to `main`, every night — with a `contents: read`
  token, which `actions/checkout` also left in `.git/config` for every later
  step. No secret is in those workflows, no cache is used, and the
  self-hosted runner is not reachable from them (`render.yml`), so the reach
  was the build and its artifacts, not the release key.
- **Why the old defence fell short:** `release.yml`, `appcast.yml` and
  `render.yml` already pinned by commit; these two did not.
- **Fix:** both pinned to the v7.0.1 commits the release workflow uses, and
  `persist-credentials: false` (neither workflow pushes). Checked as well:
  no workflow uses `pull_request_target`; every one declares
  `permissions: contents: read` at the top and widens it per job only where
  it pushes (`release.yml`, `appcast.yml`); the artifacts uploaded are
  xcresults, the fuzz corpus and a crashing input — no keychain, `.p12` or key
  path is under any uploaded directory; nothing restores a cache, so there is
  none to poison.

### V2 — Nothing checked what the release signature allows

- **Attacker:** none directly; a build or signing mistake that a release
  would have shipped silently.
- **Path:** `corta-release-check` verified the signature and, for a release,
  the Developer ID, staple and Gatekeeper. A `corta-exec` that kept
  `get-task-allow` (a plain `xcodebuild build` leaves it, as `release.yml`'s
  comment records), a Sparkle helper re-signed without the hardened runtime
  or by another team, or an `LC_RPATH` into a writable directory would all
  have passed. Each lets other code run with the TCC grants every child of
  Corta inherits.
- **State of the shipped app:** sound. 1.1.8's twelve Mach-O slices (the app,
  `corta-exec`, `Sparkle`, `Autoupdate`, `Updater`, `Installer.xpc`,
  `Downloader.xpc`) all carry the hardened runtime flag (`0x10000`), team
  `646VSJ9K5F`, a Developer ID CMS signature, and none of the denied
  entitlements; the only `LC_RPATH` is `@executable_path/../Frameworks`
  (table C).
- **Fix:** the check now finds every Mach-O in the bundle by magic number
  and fails one with a denied entitlement, without the runtime flag, with a
  different team (or, for a release, none), or with a load path outside
  `@executable_path`, `@loader_path`, `/System` and `/usr/lib`. **Unproven
  until a `release.yml` dry run**: the judgements are tested, the tool's
  gathering of `codesign`/`otool` output has never run.

### V3 — A feed item could say anything besides its enclosure

- **Attacker:** anyone who gets an edit to `appcast.xml` merged on `main` —
  one maintainer credential (D20), or a change slipped into a feed pull
  request.
- **Gets:** every installed Corta reads the feed daily. The enclosure is
  EdDSA-signed, so no unsigned archive installs; but the feed is not signed,
  and Sparkle also renders release notes, opens an informational update's
  link and obeys critical, channel and phased-rollout tags. A link to a
  lookalike download page, shown in Corta's own update dialog, passed every
  check.
- **Fix:** `verify-appcast.swift`, run offline on every CI run and by the
  release check, allowlists the channel's and items' children and the
  enclosure's attributes — exactly what `generate_appcast` writes today. A3
  is the stronger, unmade fix.

## Fixed in the follow-up

At the maintainer's request A1–A5 were fixed on the same branch:

| Item | Fix |
| --- | --- |
| A1 | `perf: bound the glyph shaping one frame can run` — at most 1,024 non-ASCII shapes a frame; the rest draw next frame, requested only when nothing was evicted |
| A2 | `fix(app): decode kitty pngs in a sandboxed process of their own` — `corta-image-decoder` under `pure-computation`, spawned and reaped by `ImageDecoderProcess` |
| A3 | `build: require a signed update feed and verify before extraction` — `SURequireSignedFeed`, `SUSignedFeedFailureExpirationInterval = 0`, `SUVerifyUpdateBeforeExtraction`; `verify-appcast.swift` checks the feed's signature block (D20 amended) |
| A4 | `fix: cap the query replies one read batch can queue` — 64 KiB of whole replies per batch |
| A5 | `fix(app): check a shortcut's folder off the main thread` — the intent's `stat` moved to a background queue. The SSH-config glob already ran in `Task.detached` (this record was wrong to list it), and `ApplicationsFolderMover` reads only `/Applications` on the boot volume |

A6 (the helper lookup) is unchanged. A1 changes the render loop, so the
Release frame-CPU baseline (D17) is owed; A2 and A3 need a Mac and a release
dry run to be confirmed end to end.

## 2 · Attack chains that need verification

### A1 — Glyph-atlas thrash on the main thread (performance DoS)

- **Attacker:** hostile output; no click.
- **Path:** `GlyphAtlas` evicts a page when its caches pass 4,096 keys or its
  texture is full, and `TerminalRenderer` then rebuilds every row once
  (`TerminalRenderer.swift:270`). A screen holding more distinct clusters than
  a page keeps — base letters with two combining marks give 112² distinct
  clusters — plus one changing cell a frame would evict and re-shape the
  whole screen every frame, on the main thread that every window shares.
- **Bound:** at most one rebuild per frame (the rebuild-once rule), so it is
  sustained CPU, not an unbounded loop; output ending stops it.
- **Not reproduced.** Reproducer for a Mac:
  `python3 -c "import itertools,sys,time;m=[chr(c) for c in range(0x300,0x370)];cl=[ 'a'+x+y for x,y in itertools.product(m,m)];sys.stdout.write(''.join(cl[:200*60]))"`
  then a loop rewriting one cell; watch Corta's main-thread CPU and the
  frame time with `CORTA_RENDER_METRICS=1`. If it reproduces, the remedy is a
  per-frame shaping budget rather than a bigger cache.

### A2 — PNG decoding is ImageIO, in process, unsandboxed

`KittyImageRenderer.decodePNG` checks the PNG signature, pins the type to
`public.png`, and caps the header's dimensions before decoding — so of
ImageIO's parsers only the PNG one is reachable, and no decode is larger than
64 MB. A memory-safety bug in Apple's PNG decoder would still run in Corta,
with Corta's TCC grants. Moving decoding to an XPC service (no TCC, no
network) would contain it; that is an architecture change, recorded here,
not made. The SwiftPM fuzz harness cannot reach the app layer; fuzzing
`decodePNG` needs an app-hosted harness on a Mac.

### A3 — Sparkle's opt-in hardening is off

The shipped Sparkle (2.10.0) reads `SUVerifyUpdateBeforeExtraction` and
`SURequireSignedFeed` (both strings are in the framework binary); Corta's
`Info.plist` sets neither. With the first, an archive's EdDSA signature is
checked before any unarchiver touches it; with the second, the feed itself
must be signed, which would close what V3's allowlist only narrows
(`appcast.yml` does not sign the feed today). Their exact semantics and
defaults could not be read here (sparkle-project.org was unreachable from
this machine); both change what every installed copy accepts, so each is a
D20 decision and a `release.yml` dry run, not an edit made blind.

### A4 — Query replies amplify before back-pressure

The writer admits a chunk whenever the backlog is under 4 MB
(`TerminalSession.maxPendingWriteBytes`), and one 1 MB read batch of OSC 4
queries (`ESC]4;0;?;1;?;…`, about 4 bytes per query, about 30 bytes per
reply) queues about 7 MB of replies at once. Bounded (the next batch is
refused), never a crash or a hang; worth a reply budget per batch if it ever
shows up in memory measurements.

### A5 — Synchronous file-system calls on the main thread

`OpenTerminalWindowIntent.validatedDirectory` (`fileExists`), the
`~/.ssh/config` `Include` glob in `RemoteHosts`, and `ApplicationsFolderMover`
touch the file system on the main thread. Each needs a local user action (a
Shortcut, opening the connect sheet, launch), and only a hung network mount
makes it a hang. The hover, PTY and SFTP paths do not (S16, S18).

### A6 — Helper lookup walks past the bundle

`Spawn.locateHelperExecutable` takes the first executable `corta-exec` in up
to six ancestors of the image; in the app the first candidate is the bundled
one, so later candidates (`/Applications/corta-exec`, …) are reached only if
the bundled helper is missing — which a signed, intact bundle never is.
Defence in depth only; resolving through `Bundle.main` and stopping at the
bundle would remove the question.

## 3 · Privacy design questions

Trade-offs, not vulnerabilities; none changed here.

- **Screen capture.** Recording, screenshots, screen sharing and AirPlay
  capture terminal windows like any other. `NSWindow.sharingType = .none`
  hides a window from all of them — including the user's own screenshots and
  screen-sharing support sessions — and Apple has been narrowing what it
  blocks for ScreenCaptureKit clients. A per-window "hide from capture"
  toggle is defensible as an opt-in; as a default it breaks screen sharing.
- **Clipboard.** Copies, Copy Path, history copies and OSC 52 writes go to
  the general pasteboard with plain `.string`: Universal Clipboard (Handoff)
  syncs them to the user's other devices and clipboard managers keep them.
  `org.nspasteboard.ConcealedType` / `TransientType` tell well-behaved
  managers not to record; they do not stop Handoff. Marking OSC 52 writes
  transient (the program, not the user, chose them) is the strongest case.
- **Crash reports and diagnostics.** Corta has no crash reporter of its own.
  Apple's reports carry backtraces, loaded images and the process's
  environment-free metadata; a `precondition` message would appear, and none
  contains terminal text. Window titles are not in them. Diagnostic sharing
  is the user's system setting.
- **Accessibility.** AX clients the user granted read the grid (S18).
- **Backups.** Remote-edit copies and approvals under Application Support are
  backed up by Time Machine and are not excluded (`isExcludedFromBackup` is
  never set); S18's 30-day pruning bounds how long. Application Support is
  not in iCloud Drive. Exports go where the user saved them.
- **Password prompts.** Secure Keyboard Entry is a setting, never automatic.
  Engaging it when the foreground terminal has `ECHO` off (iTerm2's
  approach) would cover password prompts without the global cost the rest of
  the time.
- **Privacy manifest.** It declared disk space and boot time but not file
  timestamps, which Corta reads (download resume, store pruning, shader
  cache). **Fixed:** `C617.1` and `3B52.1` are declared.

## 4 · Accepted permission behaviour

- **TCC attribution.** A prompt a child triggers names Corta, and a grant
  covers every child (`SECURITY.md` §4.2). Corta itself asks only for
  notifications (`TaskNotifier`, on first use). The shipped app carries
  **no entitlements at all** (verified in 1.1.8), so under the hardened
  runtime no child can obtain camera, microphone or Apple Events access
  through Corta — the prompt cannot be granted to an app without
  `com.apple.security.device.*`/`automation.apple-events`. *Needs a Mac to
  confirm* that `osascript` in a pane fails rather than prompts. Full Disk
  Access, Files and Folders and Local Network (an `ssh` to a LAN host) are
  granted per app and do reach children — accepted, documented, never
  requested by Corta. No `NS*UsageDescription` keys are present, matching
  this.
- **Secure Keyboard Entry.** `SecureInput` is the only caller of
  `Enable/DisableSecureEventInput`, holds one bit and recomputes it from the
  setting, activation and a terminal window being key, so the counter never
  exceeds one; a sheet over a terminal window disengages it (the sheet is the
  key window). Released at quit; after a crash the system releases a dead
  process's secure input — *to confirm on a Mac*.
- **Global hotkey and Quick Terminal.** `RegisterEventHotKey` needs no
  Accessibility grant and needs a modifier (`isRegistrable`). The Quick
  Terminal activates Corta only on the hotkey or the intent, and returns
  activation to the previous app on hide; it cannot take focus on its own.
- **App Intents.** Open (directory checked to exist), focus by
  `windowID`, toggle — nothing reaches a child's stdin. Window titles are
  exposed to Shortcuts, which runs as the same user (S18).
- **Install location.** Under `~/Applications` or `~/Downloads` another
  process of the same user could replace the bundle — out of scope (§1), and
  TCC binds grants to the designated requirement (team and bundle id), so a
  replaced bundle does not inherit them. `ApplicationsFolderMover` is off for
  the development build (D22), which has another name and bundle id
  (`CortaDev.app`, `dev.noahqin.Corta.dev`), so the two cannot be mistaken
  for each other by TCC or the mover. It refuses to replace a newer installed
  copy and handles App Translocation.

## 5 · Escape sequences Corta does not implement

All of these are consumed and dropped; none is partly implemented. The rule
for each, should it ever be added:

| Sequence | Today | If implemented, it must |
| --- | --- | --- |
| DECRQSS (`DCS $ q … ST`) | DCS consumed, nothing dispatched | Answer only from a fixed table of settings Corta tracks, as numbers; never echo the request's text |
| XTGETTCAP (`DCS + q … ST`) | Same | Answer from a compiled-in table; a name not in it gets the "invalid" form, never the hex the stream sent |
| DECRQM (`CSI ? Ps $ p`) | Implemented, numeric | — |
| XTWINOPS (`CSI Ps t`) | Only 18 (text-area size) answers | Never 20/21 (icon/title report, §2.2); never move, resize or iconify the window from the stream; pixel sizes only as numbers |
| Title stack (`CSI 22/23 t`) | Ignored | Push/pop only; nothing reported |
| DECRQCRA (`CSI … * y`) | Ignored | Not at all: a checksum of screen contents is an oracle that leaks what is on screen to the program, byte by byte |
| ENQ answerback | Ignored | Constant text from config only, and empty by default |
| Sixel (`DCS … q`) | DCS consumed | The same caps as Kitty images (per image, per pane, process), decoded off the main thread |
| iTerm2 OSC 1337 | Ignored | `File=` never writes to disk without a save panel, never auto-opens; `SetUserVar`, `RemoteHost`, `CurrentDir` informational only, like OSC 7's remote context; no `RequestAttention` loop |
| OSC 9 / 777 notifications | Ignored | Rate-limited, shown as the program's text, never with actions that run anything, and off by default like OSC 52 |
| OSC 22 (pointer shape) | Ignored | A fixed set of system cursors; no image |
| OSC 50 (font) | Ignored | Never report; set only to a font family that passes D12's verification |
| OSC 52 read | Never (§2.6) | — |
| Kitty `t=f/t=t/t=s` | Refused | Not at all: the stream would name a local file for Corta to read |
| Kitty animation, Unicode placeholders | Ignored | Same budgets, and frame timing that cannot keep the main thread busy |

## Tables

### A — External input → crash or hang points → defence → coverage → result

| Entry | Peer-controlled values | Defence | Fuzz / test | Result |
| --- | --- | --- | --- | --- |
| Parser states, UTF-8 | Every byte | Diagram state machine; WHATWG decoder; ESC/CAN/SUB from any state | `corta-fuzz` (terminal), `FuzzCorpusTests` | No trap found |
| CSI parameters | Count, magnitude | 16 params; values saturate at 65535 (`Parameters.accumulate`); intermediates ≤ 2 | Same; `params-overflow.bin` | OK |
| Cursor, scroll region, ICH/DCH/IL/DL/ECH/REP-like counts | Counts ≤ 65535 | `moveCursor` clamps; `min(count, region)`; `Line.insertCells`/`deleteCells` clamp to width; tab loops stop at the margin | Same | OK |
| SGR 38/48 | Indices | `min(…, 255)`; `parameters[i]` returns 0 out of range | Same | OK |
| DSR/DA/DECRQM/XTVERSION/CSI 18 t | — | Fixed or numeric replies; write queue capped at 4 MB | Same | OK (A4 noted) |
| OSC 0/2 | 4 KiB text | `Parser.maxStringLength`; controls dropped | `--target osc` | OK |
| OSC 4/5/10–12/104/105 | Indices, colour specs | `parseByte` bounded; ≤ 4 hex digits; `scaleToByte` cannot overflow | `--target osc` | OK |
| OSC 7 | URL | `URL(string:)`; kernel-confirmed (S18) | `--target osc` | OK |
| OSC 8 | URL | ≤ 2048 bytes; table of 2047 with deferred sweep | `--target osc` | OK |
| OSC 52 | base64 | Strict decoder; sanitised; off by default | `--target osc` | OK |
| OSC 133 | Status digits | Saturates at 255 | `--target osc` | OK |
| OSC 134 | Fields | ≤ 23 fields, ≤ 512 bytes each, controls refused | `--target osc` | OK |
| APC (Kitty) parse | Keys, ids, sizes | 132 KiB cap; `UInt32(exactly:)` ids; `s`/`v` ≤ 8192, `c`/`r` ≤ 4096 | `--target kitty` | OK |
| Kitty inflate | zlib stream | Ceiling = declared pixels or 64 MB, checked per 64 KiB slice; header and Adler-32 | `--target kitty` (bomb, bad Adler seeds) | OK |
| Kitty storage, placement, cursor | Bytes, counts, pixel sizes | Pane/process budgets; 64 images, 256 placements; scroll capped at region + screen | Same | OK |
| PNG decode (app) | PNG bytes | Signature, `public.png`, header dimensions ≤ 8192² / 16 Mpx before decode | None (app layer) | A2 |
| Graphemes, combining | Scalars per cell | ≤ 32 scalars; table 65,534 with deferred sweep; concealing scalars drawn | Terminal fuzz | OK |
| Renderer instances, atlas | Distinct clusters | Ink bounds finite and ≤ atlas; rebuild once per eviction | None | A1 to measure |
| Reflow on resize | Row contents | Fuzz resizes at input-derived points | Terminal fuzz | OK |
| Hover link and path detection | Line text | ≤ 100,000 cells; linear patterns (S16) | Core tests | OK |
| SFTP frame length | `uint32` | 1 ≤ n ≤ 1 MiB before allocating | `--target sftp`, `SFTPFuzzCorpusTests` | OK |
| SFTP strings, NAME, ATTRS | Lengths, counts | Each ≤ remaining bytes; count ≤ remaining / minimum entry size | Same | OK |
| SFTP READ/DATA | Data length | Longer than asked is a protocol violation; short reads re-asked | `SFTPTransferTests` | OK |
| READDIR loop | Batches | 100,000 entries, 32 MiB per listing; tree caps | Same | OK |
| Request ids, cancellations | Late replies | Window 32; 1,024 cancelled ids, then the session ends | `SFTPRequestIDLedgerTests` | OK |
| statvfs reply | Body | Exactly eleven `uint64` or nil | `--target sftp` | OK |
| ssh stderr | Text | 64 KiB tail | — | OK |

### B — `unsafe` or `@unchecked` site → protected state → synchronisation → result

`@unchecked Sendable` and `nonisolated(unsafe)` in production code (13):

| Site | State | Synchronisation | Result |
| --- | --- | --- | --- |
| `PTY` | Descriptor, exit, reaping flag | `GuardedDescriptor` brackets every syscall; `Mutex<State>`; one `waitpid` | Necessary, verified |
| `GuardedDescriptor` (×2, byte-identical) | In-flight count, closed, released | `Mutex`; deferred close by last caller | Removable: `let` + `Mutex` is checkable `Sendable` |
| `TerminalSession` | Terminal, callbacks, write queue, resize request | `Mutex` per state; serial writer and resize queues | Necessary (`let` + `Mutex` + queues; init-time seams are `let`), verified |
| `SuspendedScreen` | Parked main grid | Immutable `let` after init | Removable (immutable class of a `Sendable` value) |
| `SFTPSession` | Ledger, in-flight, window, handshake | One `Mutex<State>`; serial writer queue; continuations resumed once, outside or under the lock as documented | Necessary, verified |
| `SFTPSubprocessChannel` | Exit, reaping, closed, stderr tail | `Mutex`es; `GuardedDescriptor`s; kill only while unreaped | Necessary, verified |
| `SFTPConnection` | Channel, engine, capabilities | `Mutex<State>` | Necessary, verified |
| `SFTPTransferEngine` | Session, admission queue | `Mutex`es; **`transferAdmissionGate` is an unsynchronised `var`**, a test seam set before transfers start; production never writes it | Verified for production; could be a `let` in init |
| `AbortFlag` | One bool | `Mutex` | Removable |
| `KittyImageRenderer` | Texture cache, budgets, in-flight | `NSLock` held only for dictionary work; decodes outside it | Necessary, verified |
| `TerminalFont.cascadeList` (`nonisolated(unsafe) static let`) | Immutable descriptor array | Written once at static init | Verified (CTFontDescriptor is immutable) |
| `corta-release-check` `Collected` | `Data` from a reader thread | `DispatchGroup.wait()` before the read | Verified; tool only |

Unsafe pointer and C interop, by file (17 production files):

| File | Operation | Result |
| --- | --- | --- |
| `Line.swift` | `withUnsafeMutableBufferPointer` after `grow(to: end)` | In bounds by construction |
| `TerminalSession.swift` | 64 KiB read buffer, `allocate`/`deallocate`, slices by `read` count | Verified |
| `PTY.swift` | `ptsname_r` (PATH_MAX buffer), `proc_pidinfo` size-checked, `proc_name` by returned length, `proc_listpgrppids` clamped, `vip_path` read as C string | Verified; `vip_path` relies on the kernel's NUL |
| `Spawn.swift`, `SFTPChannel.swift` | `strdup` argv/envp, freed in `defer`; pipes `FD_CLOEXEC`; `POSIX_SPAWN_CLOEXEC_DEFAULT`, `SETSID`, default signals | Verified; window between `pipe()` and `FD_CLOEXEC` is covered by every spawn using `CLOEXEC_DEFAULT` |
| `corta-exec/main.swift` | `strdup` argv; error pipe re-marked `FD_CLOEXEC` before `execve` | Verified |
| `SFTPSession.swift` | `readExact` into `[UInt8]` at `base + filled`, count = remaining | Verified |
| `SFTPTransferEngine.swift` | `pwrite`/`pread` at `baseAddress! + written`; `off_t(UInt64)` of local offsets | Verified; offsets come from local sizes, never a peer's |
| `ChildEnvironment.swift`, `PTYError.swift` | `String(cString:)` of `environ` / `strerror` | Verified |
| `Metal4Backend.swift` | `copyMemory` of `stride × count` bytes into a buffer sized for it | Verified |
| `KittyImageRenderer.swift` | `CGContext` over `withUnsafeMutableBytes` (draws inside the closure); `texture.replace` | Verified |
| `GlyphAtlas.swift` | `CTRunGetGlyphs` into arrays of `count` | Verified |
| `SystemMetrics.swift` | `withMemoryRebound` for `host_statistics(64)` with count ≤ capacity; `getifaddrs` walk, `freeifaddrs` in `defer` | Verified |
| `InputSourceState.swift` | `Unmanaged.takeUnretainedValue` of Get-rule TIS properties | Verified |
| `GlobalHotKey.swift` | `Unmanaged.passUnretained(self)` into Carbon; handler removed in `deinit` | Verified |
| `RemoteEditStore.swift`, `SFTPTransferEngine.swift` | `acl_init`/`acl_set_fd_np`/`acl_free` | Verified |
| `RemoteHosts.swift` | `glob`/`globfree` | Verified (A5 for mounts) |

### C — Release component → signature, entitlements, rpath → result

From the published `Corta-1.1.8.zip`, parsed directly (Python over the Mach-O
load commands and the `0xfade0cc0` superblob; not `codesign`):

| Component | Arch | Team | Runtime | Developer ID CMS | Entitlements | LC_RPATH / unusual dylibs |
| --- | --- | --- | --- | --- | --- | --- |
| `MacOS/Corta` | arm64 | 646VSJ9K5F | yes | yes | none | `@executable_path/../Frameworks` |
| `MacOS/corta-exec` | arm64 | 646VSJ9K5F | yes | yes | none | none |
| `Sparkle.framework/…/Sparkle` | arm64, x86_64 | 646VSJ9K5F | yes | yes | none | none |
| `…/Autoupdate` | arm64, x86_64 | 646VSJ9K5F | yes | yes | `application-identifier` | none |
| `…/Updater.app` | arm64, x86_64 | 646VSJ9K5F | yes | yes | none | none |
| `…/Installer.xpc` | arm64, x86_64 | 646VSJ9K5F | yes | yes | none | none |
| `…/Downloader.xpc` | arm64, x86_64 | 646VSJ9K5F | yes | yes | none | none |

No `get-task-allow`, library-validation, `DYLD_*`, JIT or unsigned-memory
entitlement anywhere. Sparkle keeps its Intel slices (D21 covers only the two
executables this project builds). `strings` over the Release executable finds
no `CORTA_SFTP_SSH`, `CORTA_STAGE_DIR` or `SFTPPreviewClient`; the `CORTA_*`
names present are the measurement and restore switches `TESTING.md` lists for
all builds. No credential, key or development endpoint string was found. The
`Info.plist` carries `SUFeedURL`, `SUPublicEDKey` and the check interval, no
usage descriptions, and no Sparkle installer/downloader service keys.

**Sparkle 2.10.0** is past every published advisory: GHSA-g3hp-f6mg-559v
(≤ 2.9.1), GHSA-hg88-v3cw-3qrh, GHSA-gmj2-gq3j-vqmj (≤ 2.9.4),
GHSA-3x7w-j75x-ppq5 and GHSA-4v99-qgq9-6pxp (≤ 2.9.5; both need a root or
system-domain installer, which Corta does not use), CVE-2025-10015/10016
(< 2.7.2) and CVE-2025-0509 (< 2.6.4). `Package.resolved` pins it by
revision; Dependabot's `swift` entry does reach it (its 2.9.6 → 2.10.0 pull
request was #153).

## Not verified, and why

The [Mac closeout of October 8–9](2026-10-09-mac-audit-closeout.md)
supersedes the original Linux-only verification boundary. SwiftPM tests and
fuzz-corpus replay, actual Metal 4 app Unit tests, TSan, Apple's signature
inspection, the signed release dry run, real signed-feed rehearsal and
isolated Sparkle rejection tests and forced-quit Secure Keyboard Entry release
have now run. The A1 reproducer found an
additional overflow-triggered full-rebuild bug, fixed with a Metal regression.
The closeout records its frame-CPU comparison and native launched-app checks.

Still not verified in the requested environment:

- Exact Swift 6.2 strict-memory-safety compilation and exhaustive table-B
  classification: this Mac has only Swift 6.4. Supplemental 6.4 builds and
  a diagnostic inventory are recorded; four unnecessary unchecked
  declarations were removed and checked by the compiler.
- The complete UI test plan: Xcode timed out enabling automation mode
  before running a case. No machine setting was changed to work around it.
- Clean-user TCC attribution (Finder, camera and Documents): no disposable
  test account was available, and this pass did not create one or grant
  permissions. Actual VoiceOver speech and the Shortcuts application's
  unreachable-directory flow remain unverified.
- Real-host SFTP retry/resume, remote editor cancellation and an SSH
  session's Reconnect button: no authorized disposable host was supplied.
- Sustained font-zoom memory reclamation beyond the measured short sample.

These are verification limits, not passes. PNG type/corpus and subprocess
limits were exercised; a broad ImageIO decoder fuzz campaign was not run.
