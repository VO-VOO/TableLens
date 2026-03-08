import Cocoa
import Carbon

struct HotkeyShortcut {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
}

enum HotkeyParser {
    static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal), "[": UInt32(kVK_ANSI_LeftBracket),
        "]": UInt32(kVK_ANSI_RightBracket), ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
        "\\": UInt32(kVK_ANSI_Backslash)
    ]

    static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Space): "space",
        UInt16(kVK_Return): "return",
        UInt16(kVK_Escape): "escape",
        UInt16(kVK_Tab): "tab",
        UInt16(kVK_Delete): "delete",
        UInt16(kVK_ForwardDelete): "forwarddelete",
        UInt16(kVK_Home): "home",
        UInt16(kVK_End): "end",
        UInt16(kVK_PageUp): "pageup",
        UInt16(kVK_PageDown): "pagedown",
        UInt16(kVK_LeftArrow): "left",
        UInt16(kVK_RightArrow): "right",
        UInt16(kVK_UpArrow): "up",
        UInt16(kVK_DownArrow): "down",
        UInt16(kVK_F1): "f1", UInt16(kVK_F2): "f2", UInt16(kVK_F3): "f3", UInt16(kVK_F4): "f4",
        UInt16(kVK_F5): "f5", UInt16(kVK_F6): "f6", UInt16(kVK_F7): "f7", UInt16(kVK_F8): "f8",
        UInt16(kVK_F9): "f9", UInt16(kVK_F10): "f10", UInt16(kVK_F11): "f11", UInt16(kVK_F12): "f12"
    ]

    static func describe(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String? {
        let filtered = modifiers.intersection([.control, .command, .option, .shift])
        var key: String?
        if let chars = characters?.lowercased(), let first = chars.first, !first.isWhitespace {
            key = String(first)
        }
        if let special = specialKeys[keyCode] {
            key = special
        }
        guard let key else { return nil }
        return normalizedHotkeyString(modifiers: filtered, key: key)
    }

    static func parse(_ raw: String) -> HotkeyShortcut? {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var keyToken: String?
        for part in parts {
            switch part {
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "command", "cmd": modifiers |= UInt32(cmdKey)
            case "option", "opt", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: keyToken = part
            }
        }
        guard let keyToken, let keyCode = keyCodes[keyToken] else { return nil }
        return HotkeyShortcut(keyCode: keyCode, modifiers: modifiers, display: raw)
    }

}
