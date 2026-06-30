import Carbon.HIToolbox
import AppKit

/// Renders a keyCode + modifier set as a human-readable shortcut string
/// (e.g. "⌘⇧D", "Right ⌥", "Space", "F5").
enum KeyDisplay {
    static func string(keyCode: Int, mods: NSEvent.ModifierFlags) -> String {
        let code = CGKeyCode(keyCode)
        // A lone modifier trigger (no extra mods): just show its name.
        if mods.isEmpty, let name = modifierNames[code] { return name }
        var s = ""
        if mods.contains(.control) { s += "\u{2303}" } // ⌃
        if mods.contains(.option)  { s += "\u{2325}" } // ⌥
        if mods.contains(.shift)   { s += "\u{21E7}" } // ⇧
        if mods.contains(.command) { s += "\u{2318}" } // ⌘
        return s + keyName(code)
    }

    private static let modifierNames: [CGKeyCode: String] = [
        55: "Left \u{2318}", 54: "Right \u{2318}",
        56: "Left \u{21E7}", 60: "Right \u{21E7}",
        58: "Left \u{2325}", 61: "Right \u{2325}",
        59: "Left \u{2303}", 62: "Right \u{2303}",
        63: "fn",
    ]

    private static let specialKeys: [CGKeyCode: String] = [
        49: "Space", 36: "\u{21A9}", 48: "\u{21E5}", 51: "\u{232B}", 117: "\u{2326}",
        53: "esc", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func keyName(_ keyCode: CGKeyCode) -> String {
        if let m = modifierNames[keyCode] { return m }
        if let s = specialKeys[keyCode]   { return s }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }

        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
