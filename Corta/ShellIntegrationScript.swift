/// B07 — the zsh snippet `ShellIntegrationInstaller` writes into `~/.zshrc`.
///
/// A Swift string constant rather than a bundled resource file: this is
/// generated content the app owns end to end (nothing else reads it, and it
/// is never edited by hand), so the single source of truth is the same file
/// that writes and removes it — one thing to keep in sync, not two.
enum ShellIntegrationScript {
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
}
