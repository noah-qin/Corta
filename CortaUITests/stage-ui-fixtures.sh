#!/usr/bin/env bash
# Copyright 2026 Noah Qin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Prepare the stages CursorAndWindowUITests, SystemStatusAndThemeEditorUITests,
# InputSourceIndicatorUITests and DirectoryCompletionUITests launch the app
# against. The UI-test runner is sandboxed: it can read
# anywhere but write only its own container, which the app cannot read, so
# a test cannot write its own config. Each test finds a directory named
# after it under the printed root, with its config and a neutral zshrc.
#
#   TEST_RUNNER_CORTA_UI_FIXTURES="$(CortaUITests/stage-ui-fixtures.sh)" \
#     xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan UI
#
# Remove the printed root once the development app has exited.
set -euo pipefail
root="$(mktemp -d /private/tmp/corta-ui-fixtures.XXXXXX)"

stage() {
  mkdir -p "$root/$1"
  printf '%b' "$2" > "$root/$1/config"
  printf "PROMPT='demo ❯ '\n" > "$root/$1/.zshrc"
}

stage measurement 'columns = 120\nrows = 40\nfont-size = 14\nrestore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/measurement/kitty-shell" <<'SH'
#!/bin/sh
sleep 2
printf '%s\n' "$PPID" > "/tmp/corta-kitty-parent-${KITTY_CASE_LABEL}.txt"
sleep 2
/opt/homebrew/bin/kitten icat --transfer-mode=stream --passthrough=none --stdin=no --use-window-size=120,40,8192,8192 --place=60x20@0x0 /tmp/corta-4096.png
printf '\nkitten-complete\n'
exec /bin/sh
SH
chmod 700 "$root/measurement/kitty-shell"
for workload in flood idle; do
  cat > "$root/measurement/energy-$workload-shell" <<SH
#!/bin/sh
printf '%s\\n' "\$PPID" > "/tmp/corta-energy-$workload-parent.txt"
SH
  if [[ "$workload" == flood ]]; then
    printf 'sleep 3\nexec /usr/bin/yes\n' >> "$root/measurement/energy-$workload-shell"
  else
    printf 'exec /bin/zsh\n' >> "$root/measurement/energy-$workload-shell"
  fi
  chmod 700 "$root/measurement/energy-$workload-shell"
done
stage session-ended 'appearance = light\ncolumns = 100\nrows = 28\nrestore-windows = false\ncursor-blink = false\ninput-source-indicator = off\nconfirm-close = false\n'
stage session-ended-narrow 'appearance = light\ncolumns = 42\nrows = 24\nrestore-windows = false\ncursor-blink = false\ninput-source-indicator = off\nconfirm-close = false\n'
stage terminal-recovery 'restore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\ncolumns = 90\nrows = 24\n'
stage cursor-oversized 'columns = 500\nrows = 300\nrestore-windows = true\ncursor-shape = bar\ncursor-blink = true\n'
stage cursor-blink 'appearance = light\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-shape = bar\ncursor-blink = true\n'
stage cursor-idle-block 'appearance = light\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-shape = block\ncursor-blink = true\n'
for name in system-status-bar system-theme-editor system-menu-preview; do
  stage "$name" 'appearance = light\nrestore-windows = false\ninput-source-indicator = off\n'
done
for language in en zh-Hans zh-Hant ja ko de fr es pt-BR; do
  stage "system-language-$language" 'appearance = light\nstatus-bar = true\nrestore-windows = false\ninput-source-indicator = off\n'
done
# The input-source indicator: a 60×18 grid each test checks with `stty size`
# before it trusts anything else it sees.
input_source='columns = 60\nrows = 18\nrestore-windows = false\nfont-size = 14\n'
stage input-source-toolbar "appearance = light\n$input_source"
stage input-source-cjk "appearance = light\n$input_source"
stage input-source-dark "appearance = dark\n$input_source"
stage input-source-prompt "appearance = light\n${input_source}input-source-indicator-position = prompt\n"
for name in input-source-toolbar input-source-cjk input-source-dark input-source-prompt; do
  printf "PROMPT='demo ❯ '\nRPROMPT=''\n" > "$root/$name/.zshrc"
done
# A shell without integration, for the fallback placement.
printf '#!/bin/sh\nexport PS1="demo ❯ "\nexec /bin/sh --noprofile --norc -i\n' > "$root/input-source-dark/plain-shell"
chmod 700 "$root/input-source-dark/plain-shell"

# Directory completion: the folders it offers, one of them hidden, one of
# them a name with a space and CJK in it.
stage history-suggestions 'restore-windows = false\nconfirm-close = false\nupdate-auto-check = false\ninput-source-indicator = off\n'
mkdir -p "$root/history-suggestions/Alpha"
cat >> "$root/history-suggestions/.zshrc" <<EOF
HISTFILE=/dev/null
print -s -- 'echo history-suggestion-proof'
print -s -- "cat $root/history-suggestions/Alternative"
EOF
stage directory-completion 'restore-windows = false\n'
for name in Alpha Another '空格 中文' .hidden; do
  mkdir -p "$root/directory-completion/Demo/$name"
done


stage compatibility 'columns = 100\nrows = 30\nfont-size = 16\nrestore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/compatibility/nvim.lua" <<'LUA'
vim.opt.termguicolors = true
vim.opt.number = true
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  '-- Corta terminal compatibility', '', 'local result = missing_value', '',
  '-- A diagnostic supplied through the LSP diagnostic API.'
})
vim.diagnostic.config({virtual_text = false, underline = true, signs = false})
vim.defer_fn(function()
  vim.api.nvim_set_hl(0, 'DiagnosticUnderlineError', {undercurl=true, sp='#ff3030'})
  vim.diagnostic.set(vim.api.nvim_create_namespace('compatibility'), 0, {{
    lnum=2, col=15, end_col=28, message='Undefined global missing_value', severity=vim.diagnostic.severity.ERROR
  }})
end, 1000)
vim.defer_fn(function()
  vim.cmd('checkhealth vim.health')
  vim.cmd('normal! /Terminal' .. string.char(13))
end, 12000)
LUA
cat > "$root/compatibility/nvim-shell" <<'SH'
#!/bin/sh
TASK_NVIM_CONFIG="${0%/*}/nvim.lua"
export SHELL=/bin/zsh
exec /opt/homebrew/bin/nvim --clean -u "$TASK_NVIM_CONFIG"
SH
chmod 700 "$root/compatibility/nvim-shell"

stage compatibility-scheme 'appearance = dark\ncolumns = 100\nrows = 30\nrestore-windows = false\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/compatibility-scheme/scheme-shell" <<'PYTHON'
#!/usr/bin/python3
import os, pathlib, select, tty
output = pathlib.Path(__file__).with_name('reports.txt')
output.write_text('')
tty.setraw(0)
os.write(1, b'\x1b[?2031hREADY')
pending = b''
while True:
    if not select.select([0], [], [], 60)[0]:
        continue
    data = os.read(0, 1024)
    if not data:
        break
    pending += data
    while b'n' in pending:
        report, pending = pending.split(b'n', 1)
        report += b'n'
        with output.open('a') as stream:
            stream.write(report.hex() + '\n')
        os.write(1, b'\r\nREPORT:' + report.hex().encode() + b'\r\n')
PYTHON
chmod 700 "$root/compatibility-scheme/scheme-shell"

# Context menus and paste warnings: real zsh, with a separate stage per policy.
for policy in dangerous always off; do
  stage "context-paste-$policy" "font-family = Menlo\nfont-size = 14\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\nopen-file-command = /usr/bin/true {file}\npaste-warning = $policy\n"
  printf 'cd "$ZDOTDIR"\nPROMPT="demo ❯ "\n' > "$root/context-paste-$policy/.zshrc"
  printf 'fixture\n' > "$root/context-paste-$policy/sample.swift"
done

stage agents 'columns = 100\nrows = 30\nfont-size = 14\nrestore-windows = false\ncursor-blink = false\nstatus-bar = false\nnotify-from-programs = false\nagent-processes = corta-stub\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/agents/status-demo" <<'SH2'
#!/bin/sh
printf '\nAgent fixture started\n'
printf '\033]7501;state=working:app=fixture:title=QnVpbGRpbmc=\007'
sleep 4
printf '\033]7501;state=blocked:app=fixture:kind=permission:title=UmV2aWV3IGNoYW5nZXM=\007'
printf '\033]9;4;4;65\007'
printf '\nBackground permission fixture\n'
sleep 20
printf '\033]7501;state=clear\007\033]9;4;0\007'
SH2
chmod 700 "$root/agents/status-demo"
cat > "$root/agents/completion-demo" <<'SH2'
#!/bin/sh
printf '\033]7501;state=working:app=claude-code\007'
printf '\nClaude completion fixture started\n'
sleep 6
printf '\033]7501;state=done:app=claude-code\007'
printf '\nReady for another turn\n'
# Keep the process alive, as a real agent does at its input prompt.
sleep 30
SH2
chmod 700 "$root/agents/completion-demo"
cat > "$root/agents/stub.swift" <<'SWIFT'
import Foundation
FileHandle.standardOutput.write(Data("fallback process started\n".utf8))
Thread.sleep(forTimeInterval: 8)
SWIFT
swiftc -module-cache-path "$root/module-cache" "$root/agents/stub.swift" -o "$root/agents/corta-stub"
cat > "$root/agents/auto-shell" <<'SH'
#!/bin/sh
export SHELL=/bin/zsh
if mkdir "$ZDOTDIR/$TEST_AGENT_MARKER" 2>/dev/null; then
  if [ "$TEST_AGENT_MODE" = fallback ]; then
    exec "$ZDOTDIR/corta-stub"
  elif [ "$TEST_AGENT_MODE" = completion ]; then
    "$ZDOTDIR/completion-demo"
  else
    "$ZDOTDIR/status-demo"
  fi
fi
exec /bin/zsh -l
SH
chmod 700 "$root/agents/auto-shell"

stage agent-notifications 'columns = 100\nrows = 30\nfont-size = 14\nrestore-windows = false\nnotify-from-programs = true\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/agent-notifications/notice-shell" <<'SH'
#!/bin/sh
export SHELL=/bin/zsh
if mkdir "$ZDOTDIR/$TEST_AGENT_MARKER" 2>/dev/null; then
  printf '\nNotification target %s\n' "$TEST_AGENT_CHANNEL"
  printf '\033]7501;state=working:app=fixture\007'
  sleep 4
  printf '\033]7501;state=blocked:app=fixture:kind=permission\007'
  case "$TEST_AGENT_CHANNEL" in
    iterm2) printf '\033]9;Corta 409 iterm2: Channel ready\007' ;;
    ghostty) printf '\033]777;notify;Corta 409 ghostty;Channel ready\007' ;;
    kitty)
      printf '\033]99;i=fixture:d=0:p=title;Corta 409 kitty\007'
      printf '\033]99;i=fixture:p=body;Channel ready\007'
      printf '\033]99;i=fixture:d=1:a=focus;\007'
      ;;
  esac
  sleep 20
  printf '\033]7501;state=clear\007'
fi
exec /bin/zsh -l
SH
chmod 700 "$root/agent-notifications/notice-shell"

stage real-claude 'columns = 120\nrows = 40\nfont-size = 14\nrestore-windows = false\nnotify-from-programs = true\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
cat > "$root/real-claude/claude-shell" <<'SH'
#!/bin/sh
export SHELL=/bin/zsh
if mkdir "$ZDOTDIR/$TEST_AGENT_MARKER" 2>/dev/null; then
  cd "$TEST_CLAUDE_CWD" || exit 1
  umask 077
  sleep 10
  settings="{\"preferredNotifChannel\":\"$TEST_AGENT_CHANNEL\",\"disableAllHooks\":true,\"permissions\":{\"ask\":[\"Bash\"]}}"
  exec /usr/bin/script -q -F "$ZDOTDIR/$TEST_AGENT_MARKER/transcript" \
    "$TEST_CLAUDE" --no-chrome --strict-mcp-config --tools Bash --permission-mode manual \
    --effort low --settings "$settings" \
    "Run exactly /usr/bin/touch $ZDOTDIR/$TEST_AGENT_MARKER/approved to create a disposable acceptance marker. Do nothing else, then reply only OK."
fi
exec /bin/zsh -f
SH
chmod 700 "$root/real-claude/claude-shell"

# Local conversation restoration: fixed public UUIDs, no actual agent account.
for scenario in one many invalid pickers real; do
  stage "space-conversation-$scenario" 'columns = 180\nrows = 50\nrestore-windows = false\nspace-panel-limit = 2\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
  conversation_stage="$root/space-conversation-$scenario"
  mkdir -p "$conversation_stage/ApplicationSupport" "$conversation_stage/project"
  cat > "$conversation_stage/.zshrc" <<'SH'
PROMPT='demo ❯ '
RPROMPT='RIGHT'
claude() { print -r -- "USER-EXECUTED-CLAUDE $*"; }
codex() { print -r -- "USER-EXECUTED-CODEX $*"; }
SH
  first='{"number":1,"name":"Conversation A","conversation":{"kind":"claude","id":"3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"}}'
  if [[ "$scenario" == many ]]; then
    sessions="$first,"'{"number":2,"name":"Conversation B","conversation":{"kind":"claude","id":"019eee77-052d-7530-af09-17a140e08123"}},{"number":3,"name":"Conversation C","conversation":{"kind":"codex","id":"2b20121e-9a9b-43cb-b12e-fde980cb41e0"}}'
    layout='{"split":{"vertical":true,"fraction":0.5,"first":{"panel":{"_0":0}},"second":{"panel":{"_0":1}}}}'
  else
    sessions="$first"
    layout='{"panel":{"_0":0}}'
  fi
  if [[ "$scenario" == invalid ]]; then
    sessions='{"number":1,"name":"Invalid Conversation","conversation":{"kind":"claude","id":"3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912; echo bad"}}'
  fi
  if [[ "$scenario" == pickers ]]; then
    sessions='{"number":1,"conversation":{"kind":"claude","source":"picker"}},{"number":2,"conversation":{"kind":"claude","source":"picker"}}'
    layout='{"split":{"vertical":true,"fraction":0.5,"first":{"panel":{"_0":0}},"second":{"panel":{"_0":1}}}}'
  fi
  conversation_project="$conversation_stage/project"
  if [[ "$scenario" == real ]]; then
    conversation_project="${CORTA_CONVERSATION_REAL_CWD:-$conversation_project}"
    cat >> "$conversation_stage/config" <<'CONFIG'
preset.real-claude.shell = /bin/zsh
preset.real-claude.env.TEST_REAL_KIND = claude
preset.real-codex.shell = /bin/zsh
preset.real-codex.env.TEST_REAL_KIND = codex
CONFIG
    cat > "$conversation_stage/.zshrc" <<'SH'
PROMPT='acceptance> '
RPROMPT=''
HISTFILE=/dev/null
# A one-shot launch in the fixture's own prompt, never a machine-wide shell hook.
# After the app relaunches these markers suppress the CLI launch so restore can fill.
if [[ -n "$TEST_REAL_KIND" && ! -e "$ZDOTDIR/started-$TEST_REAL_KIND" ]]; then
  : > "$ZDOTDIR/started-$TEST_REAL_KIND"
  if [[ "$TEST_REAL_KIND" == claude ]]; then
    CORTA_REAL_COMMAND="${(q)TEST_REAL_CLAUDE}"
  else
    CORTA_REAL_COMMAND="${(q)TEST_REAL_CODEX} --no-alt-screen"
  fi
  zle-line-init() {
    if [[ -n "$CORTA_REAL_COMMAND" ]]; then
      BUFFER="$CORTA_REAL_COMMAND"
      CURSOR=${#BUFFER}
      unset CORTA_REAL_COMMAND
      zle accept-line
    fi
  }
  zle -N zle-line-init
fi
SH
    sessions='{"number":1,"name":"Real Claude","presetName":"real-claude"},{"number":2,"name":"Real Codex","presetName":"real-codex"}'
    layout='{"split":{"vertical":true,"fraction":0.5,"first":{"panel":{"_0":0}},"second":{"panel":{"_0":1}}}}'
  fi
  cat > "$conversation_stage/ApplicationSupport/space.json" <<JSON
{"version":1,"introductionShown":true,"projects":[{"path":"$conversation_project","sessions":[$sessions],"layout":$layout,"nextNumber":4}]}
JSON
done

# Space grid cases need separate stages because UI actions persist their layout.
for scenario in testSpaceGridSidebarAndModes testFullScreenAndSidebarToggle testDarkSpaceScreenshot; do
  appearance=light
  [[ "$scenario" == testDarkSpaceScreenshot ]] && appearance=dark
  stage "space-grid-$scenario" "appearance = $appearance\nrestore-windows = false\ncolumns = 180\nrows = 50\nspace-panel-limit = 3\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n"
  grid_stage="$root/space-grid-$scenario"
  web="$grid_stage/projects/web-app"
  api="$grid_stage/projects/api-server"
  mkdir -p "$web/src" "$api" "$grid_stage/ApplicationSupport"
  sessions=""
  for number in 1 2 3 4 5; do
    [[ -n "$sessions" ]] && sessions+=","
    sessions+="{\"number\":$number,\"directory\":\"$web\"}"
  done
  cat > "$grid_stage/ApplicationSupport/space.json" <<JSON
{"version":1,"introductionShown":true,"selectedProject":"$web","projects":[
 {"path":"$web","sessions":[$sessions],"layout":{"split":{"vertical":true,"fraction":0.5,"first":{"panel":{"_0":0}},"second":{"split":{"vertical":false,"fraction":0.5,"first":{"panel":{"_0":1}},"second":{"panel":{"_0":2}}}}}},"nextNumber":6},
 {"path":"$api","sessions":[{"number":1,"directory":"$api"}],"layout":{"panel":{"_0":0}},"nextNumber":2}
]}
JSON
done

# Release Space flood stages: each visible session owns an independent producer.
for count in 1 6; do
  stage "space-flood-$count" 'font-size = 10\ncolumns = 240\nrows = 64\nspace-panel-limit = 6\nrestore-windows = false\nconfirm-close = false\nsecure-keyboard-entry = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
  flood="$root/space-flood-$count"
  mkdir -p "$flood/project" "$flood/ApplicationSupport"
  cat > "$flood/producer" <<'SH'
#!/bin/sh
sleep 2
exec /usr/bin/yes
SH
  chmod 700 "$flood/producer"
  printf 'preset.flood.shell = %s/producer\n' "$flood" >> "$flood/config"
  python3 - "$flood" "$count" <<'PYCODE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);count=int(sys.argv[2]);project=str(root/'project')
def panel(i): return {'panel': {'_0': i}}
def split(v,a,b,f=0.5): return {'split': {'vertical':v,'fraction':f,'first':a,'second':b}}
layout=panel(0) if count==1 else split(True,split(False,panel(0),panel(1)),
    split(True,split(False,panel(2),panel(3)),split(False,panel(4),panel(5))),1/3)
sessions=[{'number':i+1,'directory':project,'presetName':'flood'} for i in range(count)]
(root/'ApplicationSupport/space.json').write_text(json.dumps({'version':1,'introductionShown':True,'selectedProject':project,
 'projects':[{'path':project,'sessions':sessions,'layout':layout,'nextNumber':count+1}]}))
PYCODE
done

# Space SSH dialog: local sessions only; no real destination or credentials.
mkdir -p "$root/space-ssh/ApplicationSupport" "$root/space-ssh/project"
cat > "$root/space-ssh/config" <<'CONFIG'
appearance = light
restore-windows = false
columns = 100
rows = 30
CONFIG
cat > "$root/space-ssh/.zshrc" <<'ZSH'
PROMPT='demo ❯ '
RPROMPT=''
ZSH
cat > "$root/space-ssh/ApplicationSupport/space.json" <<JSON
{"version":1,"introductionShown":true,"selectedProject":"$root/space-ssh/project","projects":[{"path":"$root/space-ssh/project","sessions":[{"number":1}],"layout":{"panel":{"_0":0}},"nextNumber":2}]}
JSON
stage space-trust 'restore-windows = false\nconfirm-close = false\nsecure-keyboard-entry = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
mkdir -p "$root/space-trust/ApplicationSupport" "$root/space-trust/project"
for name in space.json .corta sessions; do
  printf '{"shell":"/usr/bin/touch","arguments":["%s/should-not-exist"]}\n' "$root/space-trust" > "$root/space-trust/project/$name"
done
cat > "$root/space-trust/ApplicationSupport/space.json" <<JSON
{"version":1,"introductionShown":true,"selectedProject":"$root/space-trust/project","projects":[{"path":"$root/space-trust/project","sessions":[{"number":1}],"layout":{"panel":{"_0":0}},"nextNumber":2}]}
JSON
printf '%s\n' "$root"
