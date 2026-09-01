extension Performer {
    /// DECSET / DECRST — `CSI ? Pm h` / `CSI ? Pm l`. Only the flags the app
    /// layer reads are tracked; every other mode is ignored cleanly
    /// (`SECURITY.md` §3). `?1049` (alternate screen) lands with M2.3.
    mutating func applyPrivateModes(_ parameters: Parameters, enabled: Bool) {
        var index = 0
        while index < parameters.count {
            switch parameters[index] {
            case 2004:  // bracketed paste (M2.6)
                state.bracketedPasteEnabled = enabled
            case 1006:  // SGR mouse reporting (M2.7)
                state.sgrMouseEncodingEnabled = enabled
            default:
                break
            }
            index += 1
        }
    }
}
