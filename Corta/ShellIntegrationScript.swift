// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

/// The snippets `ShellIntegrationInstaller` writes, one per shell. String
/// constants, not resources: the file that writes and removes them is
/// their single source of truth.
enum ShellIntegrationScript {
    /// Each emits FinalTerm A/B/C/D plus OSC 7 through the shell's own hooks.
    static func script(for shell: ShellKind) -> String {
        switch shell {
        case .zsh: return zsh
        case .bash: return bash
        case .fish: return fish
        }
    }
    /// zsh (states per `Performer+ShellIntegration.swift`): `preexec` emits
    /// `C`; `precmd` emits `D` with `$?` read first, then `A`; `B` is appended
    /// to `$PS1`, so it fires where the prompt ends, however many lines.
    ///
    /// OSC 7's path is percent-encoded byte by byte in every shell: a URL
    /// cuts a raw `C# projects` at the `#` and `what?` at the `?`, and a
    /// directory named with ESC or BEL — from an archive, say — wrote its
    /// own escape sequences on every prompt. zsh's `print -r`, because plain
    /// `print` turns a `\e` in the name into ESC.
    /// `CORTA_SHELL_INTEGRATION_ACTIVE` keeps a double source from doubling
    /// hooks. A raw literal, so zsh's `\e` and `\a` aren't doubled.
    static let zsh = #"""
        if [[ -n "$ZSH_VERSION" && -z "$CORTA_SHELL_INTEGRATION_ACTIVE" ]]; then
          CORTA_SHELL_INTEGRATION_ACTIVE=1

          __corta_preexec() {
            print -n '\e]133;C\a'
          }

          __corta_urlencode() {
            emulate -L zsh
            setopt extendedglob no_multibyte
            typeset -g __corta_url=${1//(#m)[^A-Za-z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH ))}}
          }

          __corta_precmd() {
            local __corta_status=$?
            print -n "\e]133;D;${__corta_status}\a"
            __corta_urlencode "$PWD"
            print -rn -- $'\e]7;file://'"${HOST}${__corta_url}"$'\e\\'
            print -n '\e]133;A\a'
          }

          autoload -Uz add-zsh-hook
          add-zsh-hook preexec __corta_preexec
          add-zsh-hook precmd __corta_precmd

          if [[ "$PS1" != *'\e]133;B\a'* ]]; then
            PS1="${PS1}%{"$'\e]133;B\a'"%}"
          fi
        fi
        """#

    /// bash: a `DEBUG` trap and `PROMPT_COMMAND`. The trap fires for
    /// `PROMPT_COMMAND` too; the `$BASH_COMMAND` guard stops a second `C`.
    /// It also fires for every part of `PROMPT_COMMAND` and the rest of the
    /// startup files, so preexec is armed by the last part of the prompt
    /// command and disarmed by the first command after it: one `C` per
    /// command line, and none before the first prompt.
    ///
    /// The block also sits in the login file, which `~/.profile` may be — read
    /// by `sh` and `dash` as well, and by a non-interactive `bash -lc` whose
    /// output must not gain escape sequences. So the opening test is POSIX
    /// and asks for an interactive bash; the rest only parses elsewhere.
    static let bash = #"""
        if [ -n "$BASH_VERSION" ] && [ -z "$CORTA_SHELL_INTEGRATION_ACTIVE" ] && case $- in *i*) true ;; *) false ;; esac; then
          CORTA_SHELL_INTEGRATION_ACTIVE=1

          __corta_preexec() {
            [[ -n "$COMP_LINE" ]] && return
            [[ -z "$__corta_armed" ]] && return
            __corta_armed=
            printf '\e]133;C\a'
          }

          __corta_arm() {
            __corta_armed=1
          }

          __corta_urlencode() {
            local LC_ALL=C __corta_s=$1 __corta_c __corta_i=0
            __corta_url=
            # `while`, not `for ((…))`: this file may be `~/.profile`, and dash
            # must still parse it.
            while [ "$__corta_i" -lt "${#__corta_s}" ]; do
              __corta_c=${__corta_s:__corta_i:1}
              __corta_i=$((__corta_i + 1))
              case $__corta_c in
                [A-Za-z0-9/._~-]) __corta_url+=$__corta_c ;;
                *)
                  printf -v __corta_c '%d' "'$__corta_c"
                  printf -v __corta_c '%%%02X' $(( __corta_c & 255 ))
                  __corta_url+=$__corta_c ;;
              esac
            done
          }

          __corta_precmd() {
            local __corta_status=$?
            __corta_armed=
            printf '\e]133;D;%s\a' "$__corta_status"
            __corta_urlencode "$PWD"
            printf '\e]7;file://%s%s\e\\' "$HOSTNAME" "$__corta_url"
            printf '\e]133;A\a'
          }

          trap '__corta_preexec' DEBUG
          PROMPT_COMMAND="__corta_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __corta_arm"

          if [[ "$PS1" != *'\e]133;B\a'* ]]; then
            PS1="${PS1}\[\e]133;B\a\]"
          fi
        fi
        """#

    /// fish: nothing fires after the prompt draws, so the user's
    /// `fish_prompt` is renamed (once) and wrapped: read `$status`, emit `A`,
    /// call the original, emit `B`. fish 4 sends `A`, `C` and `D` itself
    /// unless its `mark-prompt` feature is off (`test-feature` answers 1;
    /// 2 is a fish that predates the flag); then only `B` is added — fish
    /// sends none before 4.3, and a second is harmless.
    static let fish = #"""
        if status is-interactive; and not set -q CORTA_SHELL_INTEGRATION_ACTIVE
          set -gx CORTA_SHELL_INTEGRATION_ACTIVE 1

          status test-feature mark-prompt
          set -l __corta_feature $status
          set -l __corta_major (string split -f1 . -- $version)
          if test $__corta_feature -ne 1 -a "$__corta_major" -ge 4 2>/dev/null
            set -g __corta_fish_marks_prompt 1
          end

          function __corta_preexec --on-event fish_preexec
            set -q __corta_fish_marks_prompt; or printf '\e]133;C\a'
          end

          if not functions -q __corta_original_fish_prompt
            functions -c fish_prompt __corta_original_fish_prompt
          end

          function fish_prompt
            set -l __corta_status $status
            set -l __corta_prompt (__corta_original_fish_prompt | string collect -N)
            set -q __corta_fish_marks_prompt; or printf '\e]133;D;%s\a' $__corta_status
            printf '\e]7;file://%s%s\e\\' (hostname) (string escape --style=url -- "$PWD")
            set -q __corta_fish_marks_prompt; or printf '\e]133;A\a'
            printf '%s' $__corta_prompt
            printf '\e]133;B\a'
          end
        end
        """#
}
