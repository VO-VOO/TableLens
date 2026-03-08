import Cocoa

func normalizedHotkeyString(modifiers: NSEvent.ModifierFlags, key: String) -> String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("control") }
    if modifiers.contains(.command) { parts.append("command") }
    if modifiers.contains(.option) { parts.append("option") }
    if modifiers.contains(.shift) { parts.append("shift") }
    parts.append(key.lowercased())
    return parts.joined(separator: "+")
}

func hotkeyDisplayString(from normalized: String) -> String {
    let parts = normalized.lowercased().split(separator: "+").map(String.init)
    var symbols = ""
    var keyPart = ""
    for part in parts {
        switch part {
        case "control": symbols += "⌃"
        case "command": symbols += "⌘"
        case "option": symbols += "⌥"
        case "shift": symbols += "⇧"
        case "space": keyPart = "Space"
        case "return", "enter": keyPart = "↩"
        case "escape": keyPart = "⎋"
        case "tab": keyPart = "⇥"
        case "delete": keyPart = "⌫"
        case "forwarddelete": keyPart = "⌦"
        case "left": keyPart = "←"
        case "right": keyPart = "→"
        case "up": keyPart = "↑"
        case "down": keyPart = "↓"
        case "pageup": keyPart = "⇞"
        case "pagedown": keyPart = "⇟"
        case "home": keyPart = "↖"
        case "end": keyPart = "↘"
        default:
            keyPart = part.count == 1 ? part.uppercased() : part.uppercased()
        }
    }
    return symbols + keyPart
}
