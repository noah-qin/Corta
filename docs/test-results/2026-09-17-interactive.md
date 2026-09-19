# Interactive test record — 2026-09-16 to 17

Code under test: `d63bf35`. Machine: Mac17,3, macOS 27.0 (26A428). Debug
and Release builds of the current tree both succeeded. The UI was driven
by a computer-control tool and then by a person at the keyboard; no
source reading or unit test stood in for a human judgement. "Skipped"
below includes sub-items the tool could not verify reliably, and does not
license flipping a whole *not judged* group in `CONFORMANCE.md` to pass.

*Translated from the Chinese original on 2026-09-19; the findings are
unchanged.*

## Environment and important limits

- The build under formal test was confirmed to use
  `/tmp/corta-stage/config`; the path was visible on the Settings page.
  SSH used only the host the user named; the report stores no password.
- **Isolation anomaly during setup.** The old Debug bundle picked by
  directory timestamp was a 15 September build; once launched it showed
  the real configuration values instead of the staged ones. The real
  `~/.config/corta/config` has an mtime of 16 September 22:36, which
  overlaps that launch; the file is in the old format, with the newer keys
  in the unknown-keys block. With no prior copy, it cannot be proven that
  the contents did not change, and no speculative restore was made. The
  old bundle was stopped, the tree rebuilt, and the staged path verified
  before continuing.
- The UI tool's `typeText` lost some punctuation in this round:
  `Aa@12:>!` showed as `Aa@12` in `cat`, and Python's `corta_test(4)`
  as `cortatest4`. Pasting the same Python call was correct. Some keyboard
  conclusions are therefore left as skipped / awaiting a human re-test.
- The Chinese-language review used a single-process
  `-AppleLanguages '(zh-Hans)'`; no persistent AppleLanguages preference
  was written. The translation catalog and its review states were not
  modified.

## Item-by-item results

| Item | Verdict | Observed behaviour and limits |
|---|---|---|
| A1 Chinese IME | Skipped | No verifiable native Pinyin candidate window or composition was obtained; typing Han characters directly was not passed off as an IME test. Candidate placement in the left and right panes not judged. |
| A1 Claude Tab | Pass | In Claude Code 2.1.273, `/he` was confirmed on screen, Tab was pressed, and the result was `/help`; Esc closed the slash menu. Up/Down were sent, but the change of highlighted row was not verified frame by frame, so that sub-item is skipped. No model request was sent. |
| A2 fzf / Vim | Pass / Skipped | In a four-item fzf list, Up + Tab multi-selected alpha and beta, the count read 2, and Return printed both. Ctrl-J/K and Down were sent but each move was not verified independently. Esc and colon injection into Vim/Neovim were unreliable, so "no delay" could not be judged; that part is skipped. |
| A3 Option | Pass / Skipped | After adding `option-as-meta = true` the config hot-reloaded, and Option-B moved the cursor in `echo alpha beta` to the start of `beta`. With the default, Option-E then E produced `e`; because of synthetic-input and input-source limits, dead-key combinations are not judged. |
| B5 Install integration | Pass | Settings showed *Installed in ~/.zshrc*; the diff contained only the added, marker-delimited integration block. A new pane loaded it successfully. |
| B6 Marks and navigation | Pass / Skipped | `false`, `true` and `ls` were run in turn; the left-hand mark for `false` was red, success green. ⇧⌘↑ was sent, but all commands were on one visible screen, so the navigation position was not proven; the three jump sub-items are skipped. |
| B7 Output and history | Fail | Copy Last Command Output pasted the `ls` output without the prompt — that sub-item passes. Command History showed time and success/failure state, but no command text and no search field, so `ls` could not be searched for. |
| B8 Notifications | Skipped | `sleep 8` was run and an application switch attempted, but no system notification or click-back result was captured; cannot be recorded as a pass. |
| B9 Directory navigation | Pass | From the repository's `Corta` subdirectory, Project Root gave `pwd` = `/Users/noah/Developer/personal/Corta`. Finder selected the `Corta` folder inside `personal` — the right location. |
| B10 Remove integration | Pass | After Remove, the state read *not installed*; `diff` against the prior backup was empty and both SHA-1s were `c3289aa394bdc31436d8af6b08b80f1934209439`. |
| C11 Window restore | Pass (qualified) | After `kill -9`, two top-level windows were restored: one 50:50 two-pane split and one three-tab group. The first pane's `pwd` was `/private/tmp`; the other was also under tmp. A non-equal drag could not be established, so non-equal proportions are skipped. The tab window also went from 30 rows to 32; whether the selected tab was restored exactly was not judged. |
| C12 Zoom | Pass / Skipped | The Bigger menu item took both panes of one window from 58×30 to 51×28, and ⌘0 restored 58×30. Cross-window independence and relaunch with a zoom active were not completed. Injecting ⌘= produced a literal `+`, a tool limitation, so the shortcut is not judged. |
| C13 Close protection | Pass | With `sleep 100` running, both ⌘W and ⌘Q raised the running-process confirmation; after cancelling, `pgrep` still found `sleep 100`. |
| D14 VoiceOver | Skipped | No human listening check; AX text was not used in place of judging what is spoken for history and selection. |
| D15 Chinese review | Fail (copy) | Read the three Settings tabs, the Shell/View/Window menus, the command palette, the Quick Terminal and the Secure Keyboard Entry hint. The menu-bar titles were still File/Shell/Edit/View/Window/Help; the bell value *Visual* was untranslated; the close confirmation still said "pane"; one menu mixed 窗格 and 面板. Suggestions below. Not every state of the Quick Terminal status row was covered. |
| D16 Displays / full screen | Pass / Skipped | Vim entering and leaving full screen went 120×30 → 207×62 → 120×30 with content and grid redrawn correctly. External-display scale changes, unplugging and window migration need physical action; skipped this round. |
| E17 Energy | Skipped | `sudo -n true` reported *password required*; no `powermetrics` wattage. The script also hard-codes the real config/state paths, which did not meet this round's isolation requirement, so it was not run as-is. No number to write into PERFORMANCE. |
| F18 Remote context | Fail (partial) | SSH login succeeded; after a remote `cd /tmp` the shell-provided title directory updated, but the Corta badge stayed at *host unknown*. The remote had no OSC 7 integration installed, and an ordinary shell title is not treated as a full badge. ⌘D opened a new local pane with `pwd` = `/Users/noah` — pass. |
| F19 Reconnect | Pass | `exit` showed *Connection closed*; Reconnect to Host was enabled and clicking it started SSH again with a password prompt — a new connection. A second session was not logged into again. |
| F20 ProxyJump | Skipped | No ProxyJump host was provided. |
| F21 Browse remote | Fail (partial) | The editable host field appeared on first use and explained that the host was unknown — that part passes. After entering `user@host`, only *connection lost* was reported; no directory listing. |
| F22 SFTP transfer | Skipped | Blocked by F21's failure to establish SFTP: directory create/delete/rename, folder transfer and cancel/retry were all blocked. No remote file was changed. |
| F23 Remote editing | Skipped | Blocked by the SFTP connection failure; nothing was uploaded or overwritten remotely. |
| F24 Authentication error | Fail | Browse Remote Files against a password-only host failed quickly, showing only "The connection to … was lost." with no "connect once in the terminal first" or password/key guidance; it did not hang. |
| G25 tmux / htop | Fail | A private tmux socket with `htop` in each of two panes; the window was dragged from 120×30 down to 100×24 and both panes relaid out, but the bottom status/function-key rows kept ghost text from before, still visible after later refreshes. A local tmux also showed the *remote?* badge — to be investigated separately. |
| G26 Neovim wide characters | Pass (display) | The Chinese and emoji sample showed no visible column straddling, and the cursor sat on the matching cell; interactive input was limited by the tool issues above, so complex movement and editing are not judged. No test edit was saved. |
| G27 Sustained output | Pass / Fail (expected limit) | 120 s of continuous output completed 47,485 lines of about 209 characters, with `echo` in another window still responding. Short CPU samples below. Scrolling to the top only reached line 42471, not 0: the default 10,000 physical-line scrollback had evicted the early output. The literal requirement "all output can be scrolled back to the start" is therefore not met; this is not an unlimited-history configuration. |
| G28 Python REPL | Pass / Skipped | In Python 3.9.6, a pasted multi-line function kept its indentation and `corta_test(4)` returned 10. This Python does not enable bracketed paste, so Corta showed the multi-line execution warning; the bracketed-paste-on sub-item is skipped. |
| G29 git / less | Pass | Coloured commit hashes and graph rendered; `/renderer` jumped and the reverse-video highlight was visible; `G` reached `(END)`. The older search-highlight problem in the documentation did not reproduce this round. |
| G30 Sleep / wake | Skipped | No physical lid close and wake was performed; nothing can stand in for that judgement. |
| H31 Release five-point check | Pass / Skipped | The current Release build succeeded; the default AX grid was 120×30 and `stty` returned `30 120`; the screenshot was upright, long output filled the first physical row's width, and the Paste menu shortcut worked in a local shell and in Python. The pixel formula was not measured independently; ⌘= injection misbehaved, so the whole item is not recorded as a pass. |

The original list had no item 4.

## Suggested Chinese wording

- "为正在运行的命令的输出拍摄快照" → "保存当前命令输出快照".
- "在新面板中打开上级目录/项目根目录" → use "新窗格" consistently.
- "pane 中仍有任务运行时询问。" → "窗格中仍有任务运行时询问。".
- For the numeric scrollback setting, "回滚历史行数" or "保留历史行数" is
  clearer than "滚动回看".
- *Visual* → "视觉提示"; the menu-bar titles should be localised too.
- These are review suggestions for the UI copy only. They are not a
  native-speaker sign-off, and no `needs_review` state was changed to
  `translated`.

## Load samples (not an energy result)

Five `top` samples of the Release build, PID 70216: the first,
initialising sample read 0.0%, the next four 6.0%, 7.0%, 7.4% and 7.8%;
memory went from 225 MB to 231 MB. The samples cover a few seconds on a
machine running other applications, and are not evidence of a two-minute
steady-state CPU figure or a performance baseline. Wattage was not
measured.

## Cleanup

Shell integration was removed through the UI; the original `.zshrc` was
verified identical by diff and hash. The dedicated tmux server was
stopped. The final cleanup state is in the following record.

Final cleanup complete: Corta stopped, `/tmp/corta-stage` deleted; the
backup was compared with the current `.zshrc`, found identical, and
deleted. A process search found no staged or Corta processes left from
this round. The isolation anomaly against the real configuration during
setup remains as described above and was not overwritten on a guess.

## Supplementary physical-keyboard checks by the user — 2026-09-17

This section covers the synthetic-input limits noted above; sub-items
without an explicit confirmation remain pending.

- A1: the user confirmed that Pinyin `nihao` placed its candidates
  correctly and Space committed them. The repeat check in the right-hand
  split was not confirmed separately and remains pending.
- A1: ↑, ↓ and Esc in Claude's `/` menu all behaved.
- A2: ↑, ↓, Ctrl-J/K and Tab in fzf all behaved. Moving to the next item
  after a Tab selection matches this machine's fzf manual (the default
  toggle+down binding).
- A2: in `vim -u NONE`, i → abc → Esc → x behaved; the physical-keyboard
  Esc sub-item passes.
- A3: the user has not yet tested Option-E, E under the ABC input source;
  the staged config was verified to have `option-as-meta = false`.
- H31: the user confirmed ⌘V, ⌘= and ⌘0 in a local shell; the shortcut
  sub-item passes.
- New: the user reported that Claude's colours had disappeared (they were
  present before); the screenshot shows Claude Code 2.1.274's light theme
  as mostly monochrome. Recorded as an observation to locate; it cannot
  yet be attributed to Claude's configuration/environment or to Corta's
  colour rendering.
- This supplementary round recreated `/tmp/corta-stage` and launched the
  Release build; the cleanup section above describes the state at the end
  of the previous round only.

## The user's second physical round — 2026-09-17

Direct feedback from the user; supersedes the pending conclusions above.

| Item | Updated verdict | Evidence or limits |
|---|---|---|
| A1 IME in the right-hand split | Pass | The user confirmed the Pinyin candidate window followed the cursor in the right pane and text committed correctly. |
| A3 ABC dead keys | Pass | With `option-as-meta = false`, Option-E then E produced `é`. |
| Settings ⌘, | Fail | The user could not open Settings with the shortcut, only through the menu. New problem, cause not located. |
| B6 Command marks and navigation | Pass | The user confirmed the failure/success colours and ⌘↑, ⌘↓ and ⇧⌘↑ all behaved. |
| B8 Notification and click-through | Pass | The user confirmed the notification appeared and that clicking it returned to the right window and pane and landed on the corresponding command. |
| C11 Restore after force quit | Fail (display sub-item) | The user reported the rest of the restore correct, but tab 2 of window B displayed wrongly. The attached screenshot shows the tab bar covering the top line of the terminal; the content area did not clear the tab bar. Root cause undetermined. The whole item cannot be recorded as a pass. |
| C12 Zoom independence and relaunch | Pass (function) / Fail (visual) | The user confirmed independence and relaunch behaved, but the text jumped while the font was being enlarged. Needs reproducing to locate the visual jitter during zoom. |
| Reopening after closing every window | Fail | After closing all windows, clicking the app icon to open a new window made the new window flash. Recorded as a new reproduction path; whether the entry point was the Dock or something else is to be confirmed when it is located. |
| D14 VoiceOver | Anomaly, not located, not passed | What the user heard did not match the screen; it is not yet clear whether the line-by-line reading, focus, the history viewport or the selection is at fault. Kept as human feedback; AX text was not substituted for listening. |
| D16 External display / unplugging | Skipped (excluded by the user) | The user asked not to test this item this round. The full-screen sub-item was tested earlier. |
| G30 Sleep / wake | Pass (user-confirmed) | The user confirmed local input resumed with no blank or hang, that a remote session either continued or disconnected cleanly, and that Reconnect behaved. |

Screenshot evidence, described: 2026-09-17 13:33:18, three tabs visible,
the current middle tab *Corta — zsh*, with *~ — zsh* and *tmp — zsh* on
either side; the terminal's first line partly hidden by the tab bar. The
screenshot alone cannot prove the original tab order or the restored
directories; those conclusions come from the user's feedback.
