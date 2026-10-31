# Space issue acceptance

[Testing](TESTING.md) · [User guide](USER-GUIDE.md#space-projects-side-by-side)

This is the durable coverage map for the 1.6.0 Space scope: #445 and the
issues it builds on, #434, #436, #438 and #439 (#443's worktree recognition is
covered with #439). Member messaging, remote members, templates and the
worktree form (#437, #440–#442, #444, #443's second half) were removed from
1.6.0; their designs stay in those issues. Dated logs, measurements and result
bundles belong outside the tree. A skipped environment-dependent check is not
a pass; record any maintainer exclusion explicitly in the local acceptance
report or PR.

| Issue | Contract and automated coverage | Environment-dependent acceptance |
| :--- | :--- | :--- |
| [#434](https://github.com/noah-qin/Corta/issues/434) retained SSH | `RemoteTmuxTests`, `SSHIntegrationTests`, `SpaceSSHTests`, SSH removal and app SSH integration suites: off-by-default opt-in, a wrapper with no environment, forwarded socket or `allow-passthrough`, strict token handshake, independent UUIDs, exact termination, reconnect and cleanup | Run the isolated localhost SSH fixture with `--app`; inspect retention/removal dialogs and history limits. No unrelated remote session may be terminated. |
| [#436](https://github.com/noah-qin/Corta/issues/436) conversations | Core identity/record/home tests, Space conversation tests, launched conversation UI: bounded metadata, precise sources, fallback, empty-prompt fill and restoration; Resume Source and Fill Conversation Again live under the session's Diagnostics menu | Opt-in installed Claude/Codex run: verify source and timing, same-process `/clear` identity replacement, close/reopen and unsubmitted restore commands. Codex without a verified open file correctly uses `picker`. |
| [#438](https://github.com/noah-qin/Corta/issues/438) waiting queue | Queue tests and launched Space issue flows: only `blocked` is queued and counted; auth/permission/question priority; done/error/notifications are not counted; handling one never moves focus (no auto-advance); queue resets on leaving Space; count changes announce through accessibility | Check foreground/background Dock presentation and VoiceOver announcement with an interactive desktop, and that a CLI without OSC 7501 shows *State unknown · not queued*. |
| [#439](https://github.com/noah-qin/Corta/issues/439) Git sidebar | Reader tests and Space row tests: hover says new files are not checked, a clean directory shows no count; HEAD, gitdir/common refs, v2/v3/v4 indexes, multibyte strip and >20,000 cap; real FSEvents test checks tracked edits within one second and ignores untracked files; a linked worktree is marked and its main repository can be revealed (#443 first half) | Record same-machine timing when changing the bounded reader. Production never runs Git or reads tracked contents. |
| [#445](https://github.com/noah-qin/Corta/issues/445) workspace | Grid/model and launched Space tests: modes keep the window's frame, focus/PIDs, second window, persistence, unavailable folders, click-to-show with Undo/⌘Z, placement/undo, first-run note shown once, close confirmation counting hidden sessions, six-panel minimum and rebalance before replacement | Space UI suite covers sidebar, resize/full screen, layout and screenshot. Release measurement compares one and six live output producers on the same machine/toolchain. Sparkle "Install and Relaunch" with a foreground agent must show the existing "still running" confirmation (checked once by hand). |

## Repeatable checks

`SpaceIssueAcceptanceTests` runs in the ordinary Unit plan. Its independent
probe covers index-v4 strip counts above 127 bytes. `CortaSpaceTests` and
`CortaSpaceTests+IssueFlows` exercise actual windows and shells: the window's
frame across modes, click-to-show and undo, the first-run note, the close
confirmation, six-panel grids and the waiting queue.

The opt-in real conversation suite uses per-invocation test flags and minimal
prompts; it never edits user CLI configuration. Do not put credentials,
account transcripts or host-specific test setup here.

Run commands and environment prerequisites are in [Testing](TESTING.md#space-issue-acceptance).
