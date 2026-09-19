# 1.0.0 release checks — human and hardware items

Date: 2026-09-17 and 2026-09-18. Moved verbatim from `docs/CONFORMANCE.md` on 2026-09-19, where
it was written; the findings are unchanged. The procedures it ran are
[Conformance §4.4](../CONFORMANCE.md#44-app-layer-verification-requires-a-launched-app) and [§4.6](../CONFORMANCE.md#46-manual-scenario-pass).

## What the 2026-09-16/17 interactive pass changed

**The 2026-09-17 interactive pass** (`docs/test-results/2026-09-17-interactive.md`,
run by a person with a UI-driving tool and then by hand) is the first
full sweep of §4.6 and the batch-level "not judged" items since 0.1.1.
What it found and what changed as a result: ECH unimplemented (`CONFORMANCE.md` §4.4.2);
the SFTP browser reporting a refused password login as a lost connection
(`SFTPConnection.openSession` classified against a channel it had not
stored yet); a restored tab group coming back in the wrong order with the
tab bar over the first row; a transparent frame on every window reopen;
font zoom moving the titlebar instead of the bottom edge; Command History
with no command text and no text search; the menu bar unlocalised in every
language; the Bell picker showing the config-file word. Still open from
that pass, honestly, and **not blocking 1.0.0** (the CHANGELOG's release
notes list them): ⌘, not opening Settings on the tester's machine — not
reproduced by the maintainer under Pinyin with or without a composition
open, and not reproduced by the tester either in the 2026-09-18 pass
recorded below (Release and Debug builds, ABC and Pinyin, composition open, and
the palette's Settings command all opened it; `grep bind
~/.config/corta/config` showed no rebinding); the one failure is
unexplained rather than fixed — and VoiceOver, which the 2026-09-18 pass
took further (below).

## Quick Terminal — the four window-server checks, by hand and then by probe

**2026-09-18, by hand and then by probe:** ⌘T from the panel opens a
normal window and the panel grows no tab bar (tester); the
full-screen-Space case **failed** — the tester saw the panel misbehave
over a full-screen Safari, and a probe (`CGWindowListCopyWindowInfo`
over TextEdit full-screen) showed the panel's frame moving with
`kCGWindowIsOnscreen` staying false: an ordinary `NSWindow` from an
inactive application never reaches a full-screen Space. Fixed by making
the panel a non-activating `NSPanel` (CHANGELOG 1.0.0, Fixed); the same
probe then read on-screen, no Space switch, and — the focus-return
half — TextEdit frontmost and still full-screen after the dismissing
hotkey, and the panel hidden after a click into another application.
Multi-display placement stays *not judged*: the test machine has one
display.

## The six human and hardware items for 1.0.0

**2026-09-18 — the 1.0.0 human and hardware items**, run by the
maintainer at the machine, from the six-item operating guide written for
them (keypress → glass with a real keyboard, VoiceOver, ⌘,, the Quick
Terminal's four window-server checks, the Chinese UI, Touch ID and Low
Power Mode). Recorded item by item, with what each one found:

- **Keypress → glass, a person typing — measured.** `scripts/
  measure-keypress-latency.sh --manual`, 230 keystrokes on the built-in
  keyboard, AC: avg 66.3 ms, p50 67.0, p95 78.7, p99 84.5 over 200
  samples. This replaces the 0.1.1 screen-capture row (`PERFORMANCE.md`
  §5.7).
- **VoiceOver — heard, one finding.** VoiceOver's caption panel read
  the text area's description ("30 rows by 120 columns. Cursor on row
  30, column 29.") correctly against the screen, and the read-through
  steps raised nothing the tester reported. *Read selected text* over a
  six-line mouse selection (rows 287–292 of a `seq` run, highlighted on
  screen) answered **"No selection."** Probed afterwards through the
  accessibility API on the same build (`AXUIElementCopyAttributeValue`
  after a synthetic drag): `AXSelectedTextRange` and `AXSelectedText`
  both reported the selection, and `AXSelectedTextRanges` — the plural
  `NSTextView` also answers — was unsupported. That attribute is
  implemented now (`AccessibilityMappingTests.selectionIsAnsweredInBothForms`);
  whether it was VoiceOver's question is **not judged** until someone
  listens again. The trailing-`valueChanged` fix from the 17th is what
  step e (an unsent command line read as the last line) exercised; the
  tester did not report it wrong.
- **⌘, — not reproduced, second pass.** Release and Debug builds, ABC
  and Pinyin, Pinyin with a composition open, and the palette's Settings
  command: all opened Settings. `grep bind ~/.config/corta/config` found
  no rebinding. The 17 September failure stays unexplained.
- **Quick Terminal — one of four failed and is fixed.** 4a
  multi-display: not judged, one display. 4b full-screen Space: failed
  and fixed (the Quick Terminal section above, and the CHANGELOG). 4c ⌘T from the panel:
  passes. 4d focus return: verified by probe after the fix, TextEdit
  frontmost after the dismissing hotkey; the tester's own report of 4d
  was lost to a duplicated line and is not claimed.
- **Chinese UI — reviewed, by the maintainer's assistant rather than
  the tester.** Every zh-Hans string (400) was read against its English
  source and its place in the UI; twenty-one were reworded (`拷贝`
  consistently for Copy, as the system's Edit menu has it; `窗格` for
  Panes everywhere; *Zoom Pane* as `最大化窗格` so it cannot be read as
  the font zoom; question-form titles for the destructive alerts; one
  dash style; spaced units in durations) and one real defect surfaced:
  the close-confirmation title substituted English "this window"/"this
  pane"/"Corta" into every language (fixed, three keys, nine locales).
  zh-Hans is now `translated` throughout; the other seven non-English locales keep
  `needs_review` — the three new keys included — until a reader of each
  language goes through them.
- **Touch ID under Secure Keyboard Entry — passes** (later the same
  evening, after the tester enabled `pam_tid.so` through
  `/etc/pam.d/sudo_local`). `sudo -k; sudo true` in an ordinary window
  with the titlebar lock showing: the Touch ID prompt appears and the
  command passes on a fingerprint; cancelling the prompt with Esc falls
  back to `Password:` and the typed password is accepted; the same in
  the Quick Terminal panel; and with Secure Keyboard Entry switched off
  as the control. Secure input does not interfere with the Touch ID
  sheet or with the password fallback.
- **Low Power Mode — measured**, `PERFORMANCE.md` §5.6's second energy
  table. Thermal pressure stays not judged: forcing it means holding the
  machine at full load for a long time, which nothing here should do.
