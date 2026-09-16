import AppKit
import Carbon.HIToolbox

/// B16 — one system-wide hotkey, registered through Carbon's
/// `RegisterEventHotKey`.
///
/// **Why Carbon and not an `NSEvent` global monitor.** A global monitor
/// (`addGlobalMonitorForEvents`) only receives keyboard events once the user
/// has granted Corta Accessibility access in System Settings — a TCC
/// permission that also lets an app read every keystroke on the machine,
/// which is far more than a hotkey needs and exactly what `SECURITY.md` §6
/// rule 7 says not to ask for. A Carbon hotkey is dispatched by the window
/// server itself: no permission, and it keeps working while Secure Keyboard
/// Entry is on (`SecureInput`), which a monitor does not.
///
/// **Key position, not character.** Carbon identifies a hotkey by virtual
/// key code, so the letter in `quick-terminal-key = alt+space` names a key
/// cap on the ANSI layout rather than the character the current input
/// source would type. That is the same rule every other Mac hotkey utility
/// follows, and `docs/CONFIGURATION.md` says so beside the key.
@MainActor
final class GlobalHotKey {
    /// Called on the main thread each time the hotkey is pressed.
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    /// Distinguishes this hotkey from any other the process might register.
    /// One is all Corta has, but the id is what Carbon hands back, so it is
    /// checked rather than assumed.
    private static let signature: OSType = 0x4352_5441  // 'CRTA'
    private static var nextID: UInt32 = 1
    private let id: UInt32

    private(set) var shortcut: Shortcut?

    init(handler: @escaping () -> Void) {
        self.handler = handler
        id = Self.nextID
        Self.nextID += 1
    }

    /// Registers `shortcut`, replacing whatever was registered before, or
    /// unregisters everything for `nil`. Returns false when the system
    /// refused the registration — another process holds the key, or it has
    /// no virtual key code — in which case nothing stays registered.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut, let keyCode = Self.keyCode(for: shortcut.key),
            Self.isRegistrable(shortcut)
        else { return shortcut == nil }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, Self.carbonModifiers(shortcut.modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        self.shortcut = shortcut
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        shortcut = nil
    }

    /// Whether a shortcut is one the system can sensibly hold: it needs a
    /// key Carbon knows, and at least one modifier — a bare letter or the
    /// space bar claimed in every application would swallow ordinary typing
    /// everywhere.
    nonisolated static func isRegistrable(_ shortcut: Shortcut) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard !shortcut.modifiers.intersection(relevant).isEmpty else { return false }
        return keyCode(for: shortcut.key) != nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon calls back on the main thread — hotkeys are delivered
        // through the application's event target, which is the main run
        // loop — so the unmanaged pointer is dereferenced where `self`
        // lives. The handler owns no reference: `deinit` removes it before
        // the object goes.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard hotKeyID.signature == GlobalHotKey.signature, hotKeyID.id == hotKey.id
                    else { return OSStatus(eventNotHandledErr) }
                    hotKey.handler()
                    return noErr
                }
            }, 1, &spec, userData, &eventHandlerRef)
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    // MARK: - Key codes

    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// The ANSI virtual key code for a `Shortcut.key` — the character
    /// spelling a config file uses, or one of the named keys `Shortcut`
    /// already decodes to a function-key scalar.
    nonisolated static func keyCode(for key: String) -> UInt32? {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else {
            return nil
        }
        if let code = ansiKeyCodes[Character(scalar)] { return UInt32(code) }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return UInt32(kVK_UpArrow)
        case NSDownArrowFunctionKey: return UInt32(kVK_DownArrow)
        case NSLeftArrowFunctionKey: return UInt32(kVK_LeftArrow)
        case NSRightArrowFunctionKey: return UInt32(kVK_RightArrow)
        case NSHomeFunctionKey: return UInt32(kVK_Home)
        case NSEndFunctionKey: return UInt32(kVK_End)
        case NSPageUpFunctionKey: return UInt32(kVK_PageUp)
        case NSPageDownFunctionKey: return UInt32(kVK_PageDown)
        case 0x0D: return UInt32(kVK_Return)
        case 0x09: return UInt32(kVK_Tab)
        case 0x20: return UInt32(kVK_Space)
        case 0x1B: return UInt32(kVK_Escape)
        case 0x08: return UInt32(kVK_Delete)
        default: return nil
        }
    }

    /// The printable keys of the ANSI layout by the character on the key cap.
    nonisolated private static let ansiKeyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    ]
}
