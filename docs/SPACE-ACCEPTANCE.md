# Space issue acceptance

[Testing](TESTING.md) · [User guide](USER-GUIDE.md#space-projects-side-by-side)

This is the durable coverage map for #434–#445, including #438's priority,
auto-advance and accessibility comments and #440's user provenance and
Shift-click comments. Dated logs, measurements and result bundles belong outside
the tree. A skipped environment-dependent check is not a pass; record any
maintainer exclusion explicitly in the local acceptance report or PR.

| Issue | Contract and automated coverage | Environment-dependent acceptance |
| :--- | :--- | :--- |
| [#434](https://github.com/noah-qin/Corta/issues/434) retained SSH | `RemoteTmuxTests`, `SSHIntegrationTests`, `SpaceSSHTests`, SSH removal and app SSH integration suites: strict opt-in/token handshake, independent UUIDs, exact termination, reconnect and cleanup | Run the isolated localhost SSH fixture with `--app`; inspect retention/removal dialogs and history limits. No unrelated remote session may be terminated. |
| [#435](https://github.com/noah-qin/Corta/pull/435) Sparkle dependency PR | `Package.resolved` pins 2.10.1 | This number is a dependency PR, not a Space feature. Local Debug does not establish signed update delivery; artifact checks belong to the release workflow. |
| [#436](https://github.com/noah-qin/Corta/issues/436) conversations | Core identity/record/home tests, Space conversation tests, launched conversation UI: bounded metadata, precise sources, fallback, empty-prompt fill and restoration | Opt-in installed Claude/Codex run: verify source and timing, same-process `/clear` identity replacement, close/reopen and unsubmitted restore commands. Codex without a verified open file correctly uses `picker`. |
| [#437](https://github.com/noah-qin/Corta/issues/437) members | Bus/hub/contract tests and native protocol integration: scoped caller access, PID-start checks, independent inbox/history limits, all closed nudge gates, duplicate prevention, JSON-safe push, drained bounded background children, streaming MCP and wait | Opt-in real local CLI tests: Claude/Codex push both ways, same-kind Claude push and generic Grok nudge/read/reply. Record native approval/sandbox behavior separately from transport acceptance. |
| [#438](https://github.com/noah-qin/Corta/issues/438) waiting queue | Queue tests and launched Space issue flows: hidden members, auth/permission/question priority, dequeue and automatic advance; queue resets on leaving Space; count changes announce through accessibility | Check foreground/background Dock presentation and VoiceOver announcement with an interactive desktop. Auto-advance is configurable and waits for typing to stop. |
| [#439](https://github.com/noah-qin/Corta/issues/439) Git sidebar | Reader tests: HEAD, gitdir/common refs, v2/v3/v4 indexes, multibyte strip and >20,000 cap; real FSEvents test checks tracked edits within one second and ignores untracked files | Record same-machine timing when changing the bounded reader. Production never runs Git or reads tracked contents. |
| [#440](https://github.com/noah-qin/Corta/issues/440) selection to member | Contract tests check user source pane, direct conversation reply, UTF-8 truncation and total envelope budget; menus and palette share sending; Shift-click preface | Verify selection delivery through the same accepted push/nudge transport and inspect paused/no-recipient menu state. |
| [#441](https://github.com/noah-qin/Corta/issues/441) templates | Template and launched issue-flow tests: fresh identities, roles, relative paths, split tree, retention, unsubmitted commands and external-path cancellation; sequential SSH dialogs; Settings ▸ Space management | Inspect connect/cancel for multiple SSH entries and template management UI. No captured command, credential or live identity is restored. |
| [#442](https://github.com/noah-qin/Corta/issues/442) context | Contract tests: body plus envelope/context ≤64 KiB, UTF-8/control cleanup, common/packed refs; member defaults and selection choice; Git facts cached off main | Remote sessions contribute no Git context; inspect context on a real selected message when changing the UI. |
| [#443](https://github.com/noah-qin/Corta/issues/443) worktrees | Command tests enforce fixed typed command, validated branch/path and no Return; live form previews destination; session/project reveal actions use cached main-repository metadata | Confirm the unsubmitted line can be deleted, and explicit user Return followed by OSC 7 updates the Git/worktree row. |
| [#444](https://github.com/noah-qin/Corta/issues/444) remote members | JSON-safe temporary Python client, CLI/MCP parity, per-connection endpoint/token/tmux binding, rotation/revocation, stable reconnect lookup, stale-state detection and fixed nudge; D33 documents opt-in and cleanup | Opt-in Linux test verifies both protocol directions with special characters, same retained tmux PID after reconnect, disconnected delivery and old/forged credential refusal. Remote AI loops need separately authorized installed/logged-in tools. |
| [#445](https://github.com/noah-qin/Corta/issues/445) workspace | Grid/model and launched Space tests: modes, focus/PIDs, second window, persistence, unavailable folders, placement/undo, six-panel minimum and rebalance before replacement | Space UI suite covers sidebar, resize/full screen, layout and screenshot. Release measurement compares one and six live output producers on the same machine/toolchain. |

## Repeatable checks

`SpaceIssueAcceptanceTests` runs in the ordinary Unit plan. Its independent
probes cover provenance, complete message size, context cleaning, token stop and
replacement, duplicate nudges, removal/stranger access, template retention,
linked-worktree refs and index-v4 strip counts above 127 bytes.

`AgentProtocolIntegrationTests` uses real sockets, a native `corta mcp` pipe,
split/coalesced NDJSON and noisy/hung fake native push children. It does not
require vendor accounts. `CortaSpaceTests+IssueFlows` exercises actual windows,
shells, template application, six-panel grids and the waiting queue.

The opt-in real-member suite uses per-invocation test flags and minimal prompts;
it never edits user CLI configuration or registers an MCP server. The local
Linux fixture reads its target/askpass/known-hosts from a private external test
root and cleans only its own random tmux session, client directory and sockets.
Do not put credentials, account transcripts or host-specific test setup here.

Run commands and environment prerequisites are in [Testing](TESTING.md#space-issue-acceptance).
