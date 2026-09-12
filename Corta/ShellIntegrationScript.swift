/// B07 — the snippets `ShellIntegrationInstaller` writes into a shell's rc
/// file, one per supported shell.
///
/// A Swift string constant rather than a bundled resource file: this is
/// generated content the app owns end to end (nothing else reads it, and it
/// is never edited by hand), so the single source of truth is the same file
/// that writes and removes it — one thing to keep in sync, not two.
enum ShellIntegrationScript {
    /// The snippet for `shell`, all emitting the same FinalTerm A/B/C/D
    /// sequence plus OSC 7, translated to each shell's own hook mechanism.
    static func script(for shell: ShellKind) -> String {
        switch shell {
        case .zsh: return zsh
        case .bash: return bash
        case .fish: return fish
        }
    }
    /// FinalTerm's four states (`Performer+ShellIntegration.swift` has the
    /// full account) plus OSC 7 for the working directory, wired to zsh's
    /// `preexec`/`precmd` hooks:
    ///
    /// - `preexec` fires once the user has pressed Return, right before the
    ///   command runs — exactly where `C` belongs.
    /// - `precmd` fires after the command exits and before the next prompt is
    ///   drawn — `D` (with the exit status `precmd` sees first, before
    ///   anything else can clobber `$?`) followed by `A` for the prompt about
    ///   to be shown.
    /// - `B` (prompt text ends, command line begins) has no hook of its own:
    ///   it is appended to `$PS1` once, so it fires exactly when the prompt
    ///   finishes drawing, however many lines that prompt is.
    ///
    /// Guarded by `CORTA_SHELL_INTEGRATION_ACTIVE` so sourcing this twice —
    /// a `.zshrc` that itself sources other files, one of which happens to
    /// source this one again — registers each hook once.
    ///
    /// A raw string literal (`#"""`): the zsh below is full of its own
    /// backslash escapes (`\e`, `\a`), and doubling every one of them to
    /// satisfy Swift's would make this unreadable and easy to get wrong.
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

    /// bash has no `preexec`/`precmd` hooks of its own: `DEBUG` trap and
    /// `PROMPT_COMMAND` are its nearest equivalents. The trap fires before
    /// *every* simple command, including ones `PROMPT_COMMAND` itself runs —
    /// the `$BASH_COMMAND == $PROMPT_COMMAND` guard is what keeps `C` from
    /// firing a second time for the prompt machinery rather than the command
    /// the user typed.
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

    /// fish has first-class prompt events, but no hook that fires *after*
    /// the user's own prompt text is drawn — `B` needs to sit there, so this
    /// renames the user's `fish_prompt` to `__corta_original_fish_prompt`
    /// (once, guarded the same way as the other two shells) and replaces it
    /// with a wrapper that reads `$status` before anything can clobber it,
    /// emits `A`, calls through to the original, then emits `B`.
    static let fish = #"""
        if status is-interactive; and not set -q CORTA_SHELL_INTEGRATION_ACTIVE
          set -gx CORTA_SHELL_INTEGRATION_ACTIVE 1

          function __corta_preexec --on-event fish_preexec
            printf '\e]133;C\a'
          end

          if not functions -q __corta_original_fish_prompt
            functions -c fish_prompt __corta_original_fish_prompt
          end

          function fish_prompt
            set -l __corta_status $status
            printf '\e]133;D;%s\a' $__corta_status
            printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"
            printf '\e]133;A\a'
            __corta_original_fish_prompt
            printf '\e]133;B\a'
          end
        end
        """#
}
