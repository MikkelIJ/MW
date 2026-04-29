import AppKit
import Carbon.HIToolbox

/// A persisted key combination expressed in Carbon vocabulary
/// (virtual key code + Carbon modifier bitmask: `cmdKey`, `optionKey`,
/// `controlKey`, `shiftKey`).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon mask

    static let `default` = KeyCombo(keyCode: 49, modifiers: UInt32(optionKey)) // ⌥Space

    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    /// Human-readable form, e.g. "⌃⌥⌘ Space".
    var display: String {
        if isEmpty { return "—" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        if !s.isEmpty { s += " " }
        s += KeyCombo.keyName(for: keyCode)
        return s
    }

    /// Convert NSEvent modifier flags → Carbon mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command)  { m |= UInt32(cmdKey) }
        if flags.contains(.option)   { m |= UInt32(optionKey) }
        if flags.contains(.control)  { m |= UInt32(controlKey) }
        if flags.contains(.shift)    { m |= UInt32(shiftKey) }
        return m
    }

    /// Best-effort name for a virtual key code.
    static func keyName(for code: UInt32) -> String {
        // Special, non-printable keys
        switch Int(code) {
        case kVK_Space:           return "Space"
        case kVK_Return:          return "Return"
        case kVK_Tab:             return "Tab"
        case kVK_Delete:          return "Delete"
        case kVK_Escape:          return "Esc"
        case kVK_LeftArrow:       return "←"
        case kVK_RightArrow:      return "→"
        case kVK_DownArrow:       return "↓"
        case kVK_UpArrow:         return "↑"
        case kVK_Home:            return "Home"
        case kVK_End:             return "End"
        case kVK_PageUp:          return "PgUp"
        case kVK_PageDown:        return "PgDn"
        case kVK_F1:              return "F1"
        case kVK_F2:              return "F2"
        case kVK_F3:              return "F3"
        case kVK_F4:              return "F4"
        case kVK_F5:              return "F5"
        case kVK_F6:              return "F6"
        case kVK_F7:              return "F7"
        case kVK_F8:              return "F8"
        case kVK_F9:              return "F9"
        case kVK_F10:             return "F10"
        case kVK_F11:             return "F11"
        case kVK_F12:             return "F12"
        default: break
        }

        // Translate via current keyboard layout to get the printable char.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(code)" }
        let layoutData = unsafeBitCast(dataPtr, to: CFData.self) as Data
        var deadKey: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            let kl = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(kl,
                                  UInt16(code),
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKey,
                                  chars.count,
                                  &len,
                                  &chars)
        }
        if status == noErr, len > 0 {
            return String(utf16CodeUnits: chars, count: len).uppercased()
        }
        return "Key \(code)"
    }
}

extension KeyCombo {
    private static let key = "snapRegions.hotkey"

    static func load() -> KeyCombo {
        guard let data = UserDefaults.standard.data(forKey: key),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        else { return .default }
        return combo
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: KeyCombo.key)
        }
    }
}
