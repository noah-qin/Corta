extension Performer {
    /// Erasure — ECMA-48 §8.3: ED and EL.
    ///
    /// Returns false when `final` is not an erase sequence, so the dispatch
    /// table in `Performer.swift` can fall through to the next category.
    mutating func performErase(final: UInt8, parameters: Parameters) -> Bool {
        switch final {
        case 0x4A:  // ED
            switch parameters[0] {
            case 0: grid.eraseDisplay(.toEnd)
            case 1: grid.eraseDisplay(.toStart)
            case 2: grid.eraseDisplay(.all)
            // ED 3 (xterm): erase the scrollback. Not in ECMA-48, but tmux
            // and clear(1) both send it.
            case 3: grid.scrollback.removeAll()
            default: break
            }
        case 0x4B:  // EL
            switch parameters[0] {
            case 0: grid.eraseLine(.toEnd)
            case 1: grid.eraseLine(.toStart)
            case 2: grid.eraseLine(.all)
            default: break
            }
        default:
            return false
        }
        return true
    }
}
