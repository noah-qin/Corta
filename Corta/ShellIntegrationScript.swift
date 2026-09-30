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
    /// `CORTA_SHELL_INTEGRATION_ACTIVE` keeps a double source from doubling
    /// hooks. A raw literal, so zsh's `\e` and `\a` aren't doubled.
    static let zsh = #"""
        if [[ -n "$ZSH_VERSION" && -z "$CORTA_SHELL_INTEGRATION_ACTIVE" ]]; then
          CORTA_SHELL_INTEGRATION_ACTIVE=1

          __corta_preexec() {
            print -n '\e]133;C\a'
          }

          __corta_precmd() {
            local __corta_status=$?
            print -n "\e]133;D;${__corta_status}\a"
            print -n "\e]7;file://${HOST}${PWD}\e\\"
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
    static let bash = #"""
        if [[ -n "$BASH_VERSION" && -z "$CORTA_SHELL_INTEGRATION_ACTIVE" ]]; then
          CORTA_SHELL_INTEGRATION_ACTIVE=1

          __corta_preexec() {
            [[ -n "$COMP_LINE" ]] && return
            [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
            printf '\e]133;C\a'
          }

          __corta_precmd() {
            local __corta_status=$?
            printf '\e]133;D;%s\a' "$__corta_status"
            printf '\e]7;file://%s%s\e\\' "$HOSTNAME" "$PWD"
            printf '\e]133;A\a'
          }

          trap '__corta_preexec' DEBUG
          PROMPT_COMMAND="__corta_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

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
            set -q __corta_fish_marks_prompt; or printf '\e]133;D;%s\a' $__corta_status
            printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"
            set -q __corta_fish_marks_prompt; or printf '\e]133;A\a'
            __corta_original_fish_prompt
            printf '\e]133;B\a'
          end
        end
        """#
}
