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
        case .zsh: return zsh + "\n" + zshDirectoryCompletion
        case .bash: return bash
        case .fish: return fish
        }
    }
    /// zsh (states per `Performer+ShellIntegration.swift`): `preexec` emits
    /// `C`; `precmd` emits `D` with `$?` read first, then `A`; `B` is appended
    /// to `$PS1`, so it fires where the prompt ends, however many lines.
    ///
    /// `D` only after a `C`, in every shell: `precmd` also runs for the first
    /// prompt and after an empty line, where nothing finished, and a `D` there
    /// marked the prompt with the last command's status — a green rule per
    /// empty Return, or a red one after a failure.
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
            __corta_ran=1
            print -n '\e]133;C\a'
          }

          __corta_urlencode() {
            emulate -L zsh
            setopt extendedglob no_multibyte
            typeset -g __corta_url=${1//(#m)[^A-Za-z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH ))}}
          }

          __corta_precmd() {
            local __corta_status=$?
            if [[ -n "$__corta_ran" ]]; then
              print -n "\e]133;D;${__corta_status}\a"
            fi
            __corta_ran=
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
    /// `PROMPT_COMMAND` too, and after an empty line that is all it fires
    /// for: the guard on `__corta_precmd` keeps that from reading as a
    /// command.
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
            [[ "$BASH_COMMAND" == __corta_precmd* ]] && return
            __corta_armed=
            __corta_ran=1
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
            if [[ -n "$__corta_ran" ]]; then
              printf '\e]133;D;%s\a' "$__corta_status"
            fi
            __corta_ran=
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
            set -g __corta_ran 1
            set -q __corta_fish_marks_prompt; or printf '\e]133;C\a'
          end

          if not functions -q __corta_original_fish_prompt
            functions -c fish_prompt __corta_original_fish_prompt
          end

          function fish_prompt
            set -l __corta_status $status
            set -l __corta_prompt (__corta_original_fish_prompt | string collect -N)
            if set -q __corta_ran; and not set -q __corta_fish_marks_prompt
              printf '\e]133;D;%s\a' $__corta_status
            end
            set -e __corta_ran
            printf '\e]7;file://%s%s\e\\' (hostname) (string escape --style=url -- "$PWD")
            set -q __corta_fish_marks_prompt; or printf '\e]133;A\a'
            printf '%s' $__corta_prompt
            printf '\e]133;B\a'
          end
        end
        """#

    static let zshDirectoryCompletion = #"""
        if [[ -o interactive && $TERM_PROGRAM == Corta && -z $__corta_cd_installed ]]; then
          typeset -g __corta_cd_installed=1 __corta_cd_revision=0 __corta_cd_index=1
          typeset -g __corta_cd_buffer='' __corta_cd_dismissed=''
          typeset -ga __corta_cd_paths

          __corta_cd_encode() {
            emulate -L zsh
            setopt extendedglob no_multibyte
            REPLY=${1//(#m)[^A-Za-z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH ))}}
          }

          __corta_cd_refresh() {
            emulate -L zsh
            setopt extendedglob
            local prefix raw directory leaf candidatePath name packet='' encodedPrefix='' REPLY
            local -a words paths
            (( ++__corta_cd_revision ))
            [[ $BUFFER != $__corta_cd_dismissed ]] && __corta_cd_dismissed=''
            # Only a single cd argument, with the insertion point at the end.
            # Quotes are lexed by zsh; expansions other than ~/ stay with native Tab.
            if [[ $BUFFER == 'cd '* && $CURSOR == ${#BUFFER} && $BUFFER != $__corta_cd_dismissed ]]; then
              raw=${BUFFER#'cd '}
              words=( ${(z)raw} )
              if (( ${#words} <= 1 )) && [[ $raw != *[\;\|\&\<\>\`\$\(\)\{\}]* && $raw != *[[:cntrl:]]* ]]; then
                prefix=${(Q)raw}
                if [[ $prefix == */* ]]; then
                  directory=${prefix%/*}/
                  leaf=${prefix##*/}
                else
                  directory=./
                  leaf=$prefix
                fi
                [[ $directory == '~/'* ]] && directory=$HOME/${directory#'~/'}
                # Follow directory symlinks; hidden names appear only for a dot prefix.
                if [[ $leaf == .* ]]; then
                  paths=( "$directory"*(N-/D) )
                else
                  paths=( "$directory"*(N-/) )
                fi
                __corta_cd_encode "$leaf"
                encodedPrefix=$REPLY
                for candidatePath in $paths; do
                  name=${candidatePath:t}
                  [[ $name == "$leaf"* && $name != *[[:cntrl:]]* ]] || continue
                  (( ${#name} <= 128 )) || continue
                  __corta_cd_paths+=( "$candidatePath" )
                  __corta_cd_encode "$name/"
                  (( ${#packet} + ${#REPLY} + ${#encodedPrefix} < 3400 )) || { __corta_cd_paths[-1]=(); break; }
                  packet+=";$REPLY"
                  (( ${#__corta_cd_paths} >= 20 )) && break
                done
              fi
            fi
            if [[ $BUFFER != $__corta_cd_buffer ]]; then
              __corta_cd_index=1
              __corta_cd_buffer=$BUFFER
            fi
            (( __corta_cd_index > ${#__corta_cd_paths} )) && __corta_cd_index=1
            if (( ${#__corta_cd_paths} )); then
              print -rn -- $'\e]134;'"$__corta_cd_revision;$((__corta_cd_index-1));p=$encodedPrefix$packet"$'\a'
            else
              print -rn -- $'\e]134;'"$__corta_cd_revision;0"$'\a'
            fi
          }

          __corta_cd_redraw() {
            __corta_cd_paths=()
            __corta_cd_refresh
          }
          __corta_cd_next() {
            (( ${#__corta_cd_paths} )) && (( __corta_cd_index = __corta_cd_index % ${#__corta_cd_paths} + 1 ))
          }
          __corta_cd_previous() {
            (( ${#__corta_cd_paths} )) && (( __corta_cd_index = (__corta_cd_index + ${#__corta_cd_paths} - 2) % ${#__corta_cd_paths} + 1 ))
          }
          __corta_cd_accept() {
            emulate -L zsh
            local candidatePath
            if [[ $BUFFER == $__corta_cd_buffer && $CURSOR == ${#BUFFER} ]] && (( ${#__corta_cd_paths} )); then
              candidatePath=$__corta_cd_paths[$__corta_cd_index]
              [[ $candidatePath == ./* && ${candidatePath#./} != -* ]] && candidatePath=${candidatePath#./}
              BUFFER="cd ${(q)candidatePath}/"
              CURSOR=${#BUFFER}
              __corta_cd_dismissed=''
            fi
          }
          __corta_cd_dismiss() { __corta_cd_dismissed=$BUFFER; }
          autoload -Uz add-zle-hook-widget
          add-zle-hook-widget line-pre-redraw __corta_cd_redraw
          zle -N __corta_cd_next
          zle -N __corta_cd_previous
          zle -N __corta_cd_accept
          zle -N __corta_cd_dismiss
          # Bind both emacs and vi insertion maps, without replacing native Tab.
          for __corta_cd_map in emacs viins; do
            bindkey -M $__corta_cd_map $'\e[97~' __corta_cd_previous
            bindkey -M $__corta_cd_map $'\e[98~' __corta_cd_next
            bindkey -M $__corta_cd_map $'\e[99~' __corta_cd_accept
            bindkey -M $__corta_cd_map $'\e[96~' __corta_cd_dismiss
          done
          unset __corta_cd_map
        fi
        """#
}
