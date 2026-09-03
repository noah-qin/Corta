/// OSC 133 — shell integration (M7.2).
///
/// A terminal without this cannot see command boundaries. It sees keystrokes
/// leaving and bytes arriving, and everything built on "a command" has to be
/// guessed from that: `TaskNotifier` guessed from a Return keypress and an
/// output idle timer, and said so in its own comment. A shell that emits
/// `OSC 133` states the boundaries outright, and three features stop being
/// heuristics — jumping between commands, marking which ones failed, and
/// notifying when a long one actually finishes.
///
/// The four states, as FinalTerm defined them and every shell that implements
/// them uses them:
///
/// - `A` — a prompt starts here.
/// - `B` — the prompt ended; what follows is what the user is typing.
/// - `C` — the user pressed Return; what follows is the command's output.
/// - `D` — the command finished, optionally with `;<exit status>`.
///
/// Nothing here is echoed back to the child and nothing here is trusted
/// beyond a small integer: the payload's only data is an exit status, parsed
/// with a bound (`SECURITY.md` §2.1). The optional `aid=` / `cl=` parameters
/// other terminals read are ignored — Corta has no use for them, and
/// unparsed is unexploitable.
extension Performer {
    mutating func shellIntegration(_ payload: ArraySlice<UInt8>) {
        // The alternate screen is a full-screen application's canvas, not a
        // command history: a TUI that happens to emit these would leave marks
        // on rows that vanish when it exits.
        guard !grid.isAlternateScreenActive, let kind = payload.first else { return }
        switch kind {
        case 0x41:  // 'A' — prompt start
            let row = grid.absoluteRow(ofScreenRow: grid.cursor.row)
            state.promptRow = row
            state.commandExitStatus = nil
            grid.setMark(.prompt, atAbsoluteRow: row)
        case 0x42:  // 'B' — command line starts
            break
        case 0x43:  // 'C' — the command is running
            state.isCommandRunning = true
        case 0x44:  // 'D' — the command finished
            state.isCommandRunning = false
            let status = Self.exitStatus(payload)
            state.commandExitStatus = status
            state.finishedCommandExitStatus = status
            if let row = state.promptRow {
                grid.setMark(status == 0 ? .promptSucceeded : .promptFailed, atAbsoluteRow: row)
            }
        default:
            break
        }
    }

    /// `D` or `D;<status>`. A missing or unparseable status is taken as 0:
    /// a shell that reports the end of a command without a status is saying
    /// it finished, and calling that a failure would paint the history red.
    private static func exitStatus(_ payload: ArraySlice<UInt8>) -> Int {
        guard let separator = payload.firstIndex(of: 0x3B) else { return 0 }  // ';'
        var status = 0
        var sawDigit = false
        for byte in payload[payload.index(after: separator)...] {
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            status = status * 10 + Int(byte - 0x30)
            // A status is a byte in every shell that reports one; the bound
            // is here so a hostile stream cannot spin this loop into a large
            // integer.
            if status > 255 { return 255 }
        }
        return sawDigit ? status : 0
    }
}
