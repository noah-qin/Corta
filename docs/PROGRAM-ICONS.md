# Program icons

Tabs and pane headers distinguish common foreground programs. Tabs use coloured tiles and stacked icons for split panes; pane headers use monochrome marks. Full titles remain available in tooltips, and user-assigned tab names take priority.

## Coverage

43 recognised icon categories, plus the terminal fallback. Aliases share artwork; this is not a claim to recognise every CLI.

| Category | Display name | Executable aliases |
| --- | --- | --- |
| Language/runtime | Python | `python`, `python3`, `ipython`, `ipython3`, `pypy`, `pypy3` |
| AI CLI | Claude | `claude`, `claude-code` |
| AI CLI | Codex | `codex`, `codex-aarch64-apple-darwin`, `codex-x86_64-apple-darwin` |
| AI CLI | Kimi | `kimi`, `kimi-cli`, `kimi_cli` |
| AI CLI | Grok | `grok`, `grok-cli` |
| AI CLI | Gemini | `gemini`, `gemini-cli` |
| AI CLI | Qwen | `qwen`, `qwen-code` |
| AI CLI | OpenCode | `opencode`, `opencode-ai` |
| AI CLI | Aider | `aider` |
| AI CLI | Ollama | `ollama` |
| AI CLI | Copilot | `copilot`, `github-copilot-cli` |
| AI CLI | Goose | `goose` |
| Language/runtime | Node.js | `node`, `nodejs` |
| Language/runtime | Bun | `bun` |
| Language/runtime | Deno | `deno` |
| Language/runtime | Ruby | `ruby`, `irb` |
| Language/runtime | Go | `go`, `gofmt` |
| Language/runtime | Rust | `rustc`, `cargo`, `rustup` |
| Language/runtime | Java | `java`, `javac`, `jshell` |
| Language/runtime | PHP | `php` |
| Language/runtime | Lua | `lua`, `luajit` |
| Language/runtime | Swift | `swift`, `swiftc` |
| Language/runtime | Julia | `julia` |
| Language/runtime | R | `r`, `rscript` |
| Remote/tool | SSH | `ssh` |
| Remote/tool | SFTP | `sftp`, `scp`, `rsync` |
| Remote/tool | Mosh | `mosh`, `mosh-client`, `mosh-server` |
| Remote/tool | Git | `git`, `lazygit`, `tig` |
| Remote/tool | Docker | `docker`, `docker-compose`, `lazydocker` |
| Remote/tool | Kubernetes | `kubectl`, `k9s`, `helm` |
| Remote/tool | Vim | `vim`, `vi`, `view` |
| Remote/tool | Neovim | `nvim`, `neovim` |
| Remote/tool | Emacs | `emacs`, `emacsclient` |
| Remote/tool | tmux | `tmux`, `tmux: client`, `tmux: server` |
| Remote/tool | Screen | `screen` |
| Remote/tool | npm | `npm`, `npx`, `npm-cli.js`, `npx-cli.js` |
| Remote/tool | pnpm | `pnpm`, `pnpx`, `pnpm.cjs`, `pnpm.js` |
| Remote/tool | Yarn | `yarn`, `yarnpkg`, `yarn.js` |
| Remote/tool | PostgreSQL | `psql`, `pgcli` |
| Remote/tool | MySQL | `mysql`, `mariadb`, `mycli` |
| Remote/tool | Redis | `redis-cli`, `valkey-cli` |
| Remote/tool | SQLite | `sqlite`, `sqlite3` |
| Remote/tool | Processes | `top`, `htop`, `btop` |

Versioned Python, Node, Ruby, PHP and Lua process names are recognised when their suffix consists of version digits and dots.

## Interpreter-hosted tools

The process name and directory use the existing output-driven, throttled title cache. For Node, Bun, Deno and Python, a bounded kernel query can identify the script or Python module. Recognised agent entry points and selected npm package paths then select the agent icon. Inline `-e`/`-c` code, unknown options, unreadable processes and unknown scripts fall back to the interpreter's icon. Environment entries are not parsed; arguments and paths are never logged or persisted.

An SSH connection displays SSH, not a guessed remote executable: the local process cannot determine which program runs on the remote machine. Similarly, tmux/Screen represent the local multiplexer, not a claim about each program inside it. Grok matching covers `grok` and `grok-cli`; independently named third-party clients need their own aliases. Unknown tools retain the generic terminal icon and their real process name.

## Artwork and notices

AI SVGs come from [Lobe Icons](https://github.com/lobehub/lobe-icons), version 1.102.0 (MIT). Language and development-tool SVGs come from [Simple Icons](https://github.com/simple-icons/simple-icons), version 16.36.0 (CC0-1.0). SSH, SFTP/file transfer, Mosh, Aider, Screen and process monitors use system SF Symbols as generic category icons, and Java the SF Symbols cup on Java's blue: the OpenJDK mark on orange read as Claude's tile at tab size. Brand marks remain their owners' trademarks.

Original downloaded SVGs are in the app's asset catalogue; Gemini's has its arc flags written out so Xcode draws it, as its manifest entry notes. The [source manifest](program-icons-sources.json) records fixed download URLs and SHA-256 checksums. Licenses are bundled in the app and visible in About → Acknowledgements.
