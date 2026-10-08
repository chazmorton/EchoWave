import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let escape = KeyShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a shortcut from a key press, or returns nil when the combination can't be a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        let code = Int(event.keyCode)
        let hasPrimaryModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasPrimaryModifier || Self.functionKeyCodes.contains(code) else { return nil }
        self.init(keyCode: UInt32(code), modifiers: modifiers)
    }

    var displayString: String {
        modifierSymbols + Self.keyName(for: Int(keyCode))
    }

    var modifierSymbols: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// The key equivalent to show next to a menu item, when the key can be expressed as one.
    var menuKeyEquivalent: String? {
        if Int(keyCode) == kVK_Space { return " " }
        guard Self.specialKeyNames[Int(keyCode)] == nil,
              let character = KeyboardLayout.character(forKeyCode: UInt16(keyCode)),
              character.count == 1
        else { return nil }
        return character.lowercased()
    }

    static func keyName(for keyCode: Int) -> String {
        if let name = specialKeyNames[keyCode] { return name }
        return KeyboardLayout.character(forKeyCode: UInt16(keyCode))?.uppercased() ?? "Key \(keyCode)"
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_ANSI_KeypadEnter: "⌤",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// Translates between virtual key codes and characters using the active keyboard layout.
enum KeyboardLayout {
    static func character(forKeyCode keyCode: UInt16, carbonModifiers: UInt32 = 0) -> String? {
        guard let layoutData = currentLayoutData() else { return nil }
        let maxLength = 4
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: maxLength)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay),
                                  (carbonModifiers >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, maxLength, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : string
    }

    /// The key code that types "v" while ⌘ is held, so ⌘V works on Dvorak, AZERTY and friends.
    static func pasteKeyCode() -> CGKeyCode {
        for code in 0..<128 where character(forKeyCode: UInt16(code), carbonModifiers: UInt32(cmdKey))?.lowercased() == "v" {
            return CGKeyCode(code)
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    private static func currentLayoutData() -> Data? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = unicodeLayoutData(of: source) {
            return data
        }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = unicodeLayoutData(of: source) {
            return data
        }
        return nil
    }

    private static func unicodeLayoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}
