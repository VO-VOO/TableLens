import Cocoa
import Carbon
import CryptoKit
import Security
import ScreenCaptureKit

let appServiceName = "BaiduTableOCRApp"
let keychainAccount = "settings-key"
let defaultSaveDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Desktop")
    .appendingPathComponent("表格识别")

struct AppSettings: Codable {
    var apiKey: String = ""
    var secretKey: String = ""
    var saveDirectory: String = defaultSaveDirectory.path
    var hotkey: String = "control+p"
}

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

enum AppFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

final class SecureSettingsStore {
    static let shared = SecureSettingsStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(appServiceName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.enc")
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let key = try? loadOrCreateKey(),
              let sealed = try? AES.GCM.SealedBox(combined: data),
              let decrypted = try? AES.GCM.open(sealed, using: key),
              let settings = try? decoder.decode(AppSettings.self, from: decrypted)
        else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        let key = try loadOrCreateKey()
        let plain = try encoder.encode(settings)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw AppFailure.message("Failed to encrypt settings.")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: .atomic)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try? loadKeychainData() {
            return SymmetricKey(data: existing)
        }
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AppFailure.message("Failed to generate encryption key.")
        }
        try saveKeychainData(data)
        return SymmetricKey(data: data)
    }

    private func loadKeychainData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appServiceName,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw AppFailure.message("Key not found in Keychain.")
        }
        return data
    }

    private func saveKeychainData(_ data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appServiceName,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appServiceName,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppFailure.message("Failed to save encryption key to Keychain.")
        }
    }
}

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

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onTrigger: (() -> Void)?

    private init() {
        installHandlerIfNeeded()
    }

    func register(shortcut: HotkeyShortcut) {
        unregister()
        var hotKeyID = EventHotKeyID(signature: OSType(0x54424F43), id: 1) // TBOC
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                HotKeyManager.shared.onTrigger?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, nil, &eventHandler)
    }
}

final class OCRService {
    static let shared = OCRService()
    private let tokenURL = "https://aip.baidubce.com/oauth/2.0/token"
    private let tableURL = "https://aip.baidubce.com/rest/2.0/ocr/v1/table"

    // NOTE: 使用专用 URLSession，避免与 URLSession.shared 的代理队列冲突导致死锁
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.name = "BaiduOCR-Network"
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    // NOTE: 缓存 access_token，百度 token 有效期 30 天，避免每次请求都重新获取
    private var cachedToken: String?
    private var cachedTokenApiKey: String?
    private var cachedTokenSecretKey: String?
    private var tokenFetchTime: Date?
    private let tokenValidDuration: TimeInterval = 29 * 24 * 3600

    func recognizeTable(imageData: Data, settings: AppSettings, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let accessToken = try self.fetchAccessToken(apiKey: settings.apiKey, secretKey: settings.secretKey)
                let payload: [String: String] = [
                    "image": imageData.base64EncodedString(),
                    "return_excel": "true",
                    "cell_contents": "true"
                ]
                var comps = URLComponents(string: self.tableURL)!
                comps.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
                let json = try self.requestJSON(url: comps.url!, body: payload)
                if let errorCode = json["error_code"] {
                    throw AppFailure.message("Baidu OCR error: \(errorCode) \(json["error_msg"] ?? "")")
                }
                let saveDir = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
                let timestamp = Self.timestamp()
                let jsonURL = saveDir.appendingPathComponent("\(timestamp).json")
                let excelURL = saveDir.appendingPathComponent("\(timestamp).xlsx")
                let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try jsonData.write(to: jsonURL)
                guard let excelBase64 = json["excel_file"] as? String,
                      let excelData = Data(base64Encoded: excelBase64)
                else {
                    throw AppFailure.message("No excel_file returned.")
                }
                try excelData.write(to: excelURL)
                DispatchQueue.main.async { completion(.success(excelURL)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func fetchAccessToken(apiKey: String, secretKey: String) throws -> String {
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            throw AppFailure.message("请先在设置里填写百度 API Key 和 Secret Key。")
        }
        // NOTE: 当 API Key 不变且缓存未过期时，直接复用已有 token
        if let token = cachedToken,
           let fetchTime = tokenFetchTime,
           cachedTokenApiKey == apiKey,
           cachedTokenSecretKey == secretKey,
           Date().timeIntervalSince(fetchTime) < tokenValidDuration {
            return token
        }
        var comps = URLComponents(string: tokenURL)!
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: secretKey),
        ]
        let json = try requestRawJSON(url: comps.url!, method: "POST", headers: ["Content-Type": "application/json"], body: nil)
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw AppFailure.message("获取 access_token 失败。")
        }
        cachedToken = token
        cachedTokenApiKey = apiKey
        cachedTokenSecretKey = secretKey
        tokenFetchTime = Date()
        return token
    }

    private func requestJSON(url: URL, body: [String: String]) throws -> [String: Any] {
        let encoded = body.map { key, value -> String in
            let k = Self.formEncode(key)
            let v = Self.formEncode(value)
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return try requestRawJSON(url: url, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json"
        ], body: Data(encoded.utf8))
    }

    private func requestRawJSON(url: URL, method: String, headers: [String: String], body: Data?) throws -> [String: Any] {
        // FIXME: 信号量同步网络请求不能在主线程调用，否则会死锁
        assert(!Thread.isMainThread, "requestRawJSON must not be called from the main thread")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let sema = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        session.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            sema.signal()
        }.resume()
        sema.wait()
        if let resultError { throw resultError }
        guard let resultData else { throw AppFailure.message("网络请求没有返回数据。") }
        let obj = try JSONSerialization.jsonObject(with: resultData)
        guard let json = obj as? [String: Any] else {
            throw AppFailure.message("接口返回不是 JSON 对象。")
        }
        return json
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return string.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? string
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

final class SelectionOverlayView: NSView {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let image: NSImage
    private var selection: CGRect?
    private var mode: Mode = .idle
    private var dragStart: CGPoint = .zero
    private var originalSelection: CGRect = .zero
    private let accent = NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.98, alpha: 1)
    private let borderColor = NSColor.white.withAlphaComponent(0.92)
    private let handleSize: CGFloat = 10

    enum Mode {
        case idle
        case drawing
        case moving
        case resizing(Handle)
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    init(frame: CGRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(in: bounds)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.fill(bounds)

        if let selection {
            ctx.setBlendMode(.clear)
            ctx.fill(selection)
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()

        guard let selection else { return }

        NSColor.white.withAlphaComponent(0.06).setFill()
        selection.fill()

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        borderColor.setStroke()
        let border = NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()

        accent.withAlphaComponent(0.65).setStroke()
        let accentBorder = NSBezierPath(roundedRect: selection.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        accentBorder.lineWidth = 1
        accentBorder.stroke()

        NSColor.clear.set()
        NSShadow().set()

        let guides = guideLines(for: selection)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for guide in guides {
            let path = NSBezierPath()
            path.move(to: guide.0)
            path.line(to: guide.1)
            path.lineWidth = 1
            path.stroke()
        }

        for rect in handleRects(for: selection).values {
            let handlePath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            accent.setFill()
            handlePath.fill()
            borderColor.setStroke()
            handlePath.lineWidth = 1
            handlePath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        if let selection, let handle = hitHandle(at: point, in: selection) {
            mode = .resizing(handle)
            originalSelection = selection
        } else if let selection, selection.contains(point) {
            mode = .moving
            originalSelection = selection
        } else {
            mode = .drawing
            selection = CGRect(origin: point, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .drawing:
            let x = min(dragStart.x, point.x)
            let y = min(dragStart.y, point.y)
            let w = abs(point.x - dragStart.x)
            let h = abs(point.y - dragStart.y)
            selection = CGRect(x: x, y: y, width: w, height: h).standardized
        case .moving:
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            // NOTE: 用 clamping 替代 intersection，避免拖动到边界时选区被意外缩小
            var moved = originalSelection.offsetBy(dx: dx, dy: dy)
            moved.origin.x = max(0, min(moved.origin.x, bounds.width - moved.width))
            moved.origin.y = max(0, min(moved.origin.y, bounds.height - moved.height))
            selection = moved
        case .resizing(let handle):
            guard var rect = Optional(originalSelection) else { return }
            switch handle {
            case .topLeft:
                rect.origin.x = point.x
                rect.origin.y = point.y
                rect.size.width = originalSelection.maxX - point.x
                rect.size.height = originalSelection.maxY - point.y
            case .top:
                rect.origin.y = point.y
                rect.size.height = originalSelection.maxY - point.y
            case .topRight:
                rect.origin.y = point.y
                rect.size.height = originalSelection.maxY - point.y
                rect.size.width = point.x - originalSelection.minX
            case .right:
                rect.size.width = point.x - originalSelection.minX
            case .bottomRight:
                rect.size.width = point.x - originalSelection.minX
                rect.size.height = point.y - originalSelection.minY
            case .bottom:
                rect.size.height = point.y - originalSelection.minY
            case .bottomLeft:
                rect.origin.x = point.x
                rect.size.width = originalSelection.maxX - point.x
                rect.size.height = point.y - originalSelection.minY
            case .left:
                rect.origin.x = point.x
                rect.size.width = originalSelection.maxX - point.x
            }
            selection = rect.standardized.intersection(bounds)
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mode = .idle
        if let selection, selection.width < 4 || selection.height < 4 {
            self.selection = nil
        }
        needsDisplay = true
    }

    func confirmSelection() {
        guard let selection else { return }
        onConfirm?(selection.standardized)
    }

    func cancelSelection() {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Return):
            guard let selection else { return }
            onConfirm?(selection.standardized)
        case UInt16(kVK_Escape):
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }


    private func guideLines(for rect: CGRect) -> [(CGPoint, CGPoint)] {
        let thirdsX = [rect.minX + rect.width / 3, rect.minX + rect.width * 2 / 3]
        let thirdsY = [rect.minY + rect.height / 3, rect.minY + rect.height * 2 / 3]
        var lines: [(CGPoint, CGPoint)] = []
        for x in thirdsX {
            lines.append((CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)))
        }
        for y in thirdsY {
            lines.append((CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)))
        }
        return lines
    }

    private func handleRects(for rect: CGRect) -> [Handle: CGRect] {
        let midX = rect.midX
        let midY = rect.midY
        let hs = handleSize / 2
        return [
            .topLeft: CGRect(x: rect.minX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .top: CGRect(x: midX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .topRight: CGRect(x: rect.maxX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .right: CGRect(x: rect.maxX - hs, y: midY - hs, width: handleSize, height: handleSize),
            .bottomRight: CGRect(x: rect.maxX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .bottom: CGRect(x: midX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .bottomLeft: CGRect(x: rect.minX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .left: CGRect(x: rect.minX - hs, y: midY - hs, width: handleSize, height: handleSize),
        ]
    }

    private func hitHandle(at point: CGPoint, in rect: CGRect) -> Handle? {
        for (handle, handleRect) in handleRects(for: rect) where handleRect.contains(point) {
            return handle
        }
        return nil
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ScreenshotOverlayController: NSObject {
    private var window: NSWindow?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var screen: NSScreen?
    private var display: SCDisplay?
    private var localKeyMonitor: Any?

    func begin(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let screen else {
            completion(.failure(AppFailure.message("没有可用屏幕。")))
            return
        }
        self.screen = screen

        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion(.failure(AppFailure.message("无法确定当前屏幕。")))
            return
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)

        Task {
            do {
                let shareable = try await SCShareableContent.current
                guard let display = shareable.displays.first(where: { $0.displayID == displayID }) else {
                    throw AppFailure.message("无法获取当前显示器内容。")
                }
                self.display = display
                let cgImage = try await self.captureDisplayImage(display: display, sourceRect: nil)
                let image = NSImage(cgImage: cgImage, size: screen.frame.size)
                await MainActor.run {
                    let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.level = .screenSaver
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.acceptsMouseMovedEvents = true
                    window.makeKeyAndOrderFront(nil)
                    window.makeMain()
                    window.orderFrontRegardless()

                    let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image)
                    view.onCancel = { [weak self] in self?.finish(.failure(AppFailure.message("已取消截图。"))) }
                    view.onConfirm = { [weak self, weak window] rect in
                        guard let self, let window else { return }
                        self.captureSelection(rect: rect, in: window)
                    }
                    window.contentView = view
                    self.window = window
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKey()
                    window.makeMain()
                    window.makeFirstResponder(view)
                    self.installLocalKeyMonitor(for: view)
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private func installLocalKeyMonitor(for view: SelectionOverlayView) {
        removeLocalKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            switch event.keyCode {
            case UInt16(kVK_Return):
                view.confirmSelection()
                return nil
            case UInt16(kVK_Escape):
                view.cancelSelection()
                return nil
            default:
                return event
            }
        }
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func captureSelection(rect: CGRect, in window: NSWindow) {
        guard let screen, let display else {
            finish(.failure(AppFailure.message("显示器上下文丢失。")))
            return
        }
        // NOTE: SelectionOverlayView 使用 isFlipped=true（原点左上），
        // 需要先转为 window 坐标（原点左下）再转为 screen 坐标
        let windowRect: CGRect
        if let contentView = window.contentView {
            windowRect = contentView.convert(rect, to: nil)
        } else {
            windowRect = rect
        }
        let screenRect = window.convertToScreen(windowRect)
        let localX = screenRect.origin.x - screen.frame.origin.x
        let localY = screenRect.origin.y - screen.frame.origin.y
        let scale = screen.backingScaleFactor
        let sourceRect = CGRect(
            x: localX * scale,
            y: (screen.frame.height - localY - screenRect.height) * scale,
            width: screenRect.width * scale,
            height: screenRect.height * scale
        )

        Task {
            do {
                let cgImage = try await self.captureDisplayImage(display: display, sourceRect: sourceRect)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw AppFailure.message("无法编码截图 PNG 数据。")
                }
                await MainActor.run {
                    self.finish(.success(data))
                }
            } catch {
                await MainActor.run {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func captureDisplayImage(display: SCDisplay, sourceRect: CGRect?) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        if let sourceRect {
            config.sourceRect = sourceRect
            config.width = Int(sourceRect.width)
            config.height = Int(sourceRect.height)
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// NOTE: 截图完成或出错时统一清理资源
    private func finish(_ result: Result<Data, Error>) {
        removeLocalKeyMonitor()
        window?.orderOut(nil)
        window = nil
        completion?(result)
        completion = nil
    }

    /// NOTE: 外部取消当前截图流程，清理窗口和事件监听器，防止资源泄漏
    func cancel() {
        removeLocalKeyMonitor()
        window?.orderOut(nil)
        window = nil
        completion = nil
    }
}

final class HotkeyRecorderField: NSTextField {
    var onRecord: ((String?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecordingHotkey = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        beginRecording()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { beginRecording() }
        return ok
    }

    func beginRecording() {
        isRecordingHotkey = true
        stringValue = "请按下新热键"
        onRecordingChanged?(true)
        currentEditor()?.selectedRange = NSRange(location: 0, length: stringValue.count)
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        guard isRecordingHotkey else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            isRecordingHotkey = false
            onRecordingChanged?(false)
            onRecord?(nil)
            return
        }
        let filtered = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard !filtered.isEmpty else {
            NSSound.beep()
            onRecord?("__INVALID_NO_MODIFIER__")
            return
        }
        guard let hotkey = HotkeyParser.describe(modifiers: filtered, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            NSSound.beep()
            return
        }
        isRecordingHotkey = false
        stringValue = hotkeyDisplayString(from: hotkey)
        onRecordingChanged?(false)
        onRecord?(hotkey)
        window?.makeFirstResponder(nil)
    }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onSettingsChanged: ((AppSettings) -> Void)?
    private var settings: AppSettings
    private let apiKeyField = NSTextField(string: "")
    private let secretKeyField = NSSecureTextField(string: "")
    private let saveDirField = NSTextField(string: "")
    private let hotkeyField = HotkeyRecorderField(string: "")
    private let hotkeyRecordButton = NSButton(title: "录制", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    // NOTE: 防抖定时器，避免每次按键都触发加密保存和热键重注册
    private var saveTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "表格识别设置"
        super.init(window: window)
        buildUI()
        fillValues()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(makeRow(label: "百度 API Key", field: apiKeyField))
        stack.addArrangedSubview(makeRow(label: "百度 Secret Key", field: secretKeyField))

        let saveRow = NSStackView()
        saveRow.orientation = .horizontal
        saveRow.spacing = 10
        let saveLabel = makeLabel("Excel 保存目录")
        saveLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        saveDirField.delegate = self
        let browse = NSButton(title: "选择…", target: self, action: #selector(selectDirectory))
        saveRow.addArrangedSubview(saveLabel)
        saveRow.addArrangedSubview(saveDirField)
        saveRow.addArrangedSubview(browse)
        stack.addArrangedSubview(saveRow)

        let hotkeyRow = NSStackView()
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 10
        let hotkeyLabel = makeLabel("全局热键")
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        hotkeyField.isEditable = false
        hotkeyField.isBezeled = true
        hotkeyField.drawsBackground = true
        hotkeyField.onRecordingChanged = { [weak self] isRecording in
            self?.hotkeyRecordButton.title = isRecording ? "正在录制…" : "录制"
            self?.hotkeyRecordButton.isEnabled = !isRecording
        }
        hotkeyField.onRecord = { [weak self] value in
            guard let self else { return }
            if value == "__INVALID_NO_MODIFIER__" {
                self.statusLabel.stringValue = "热键必须至少包含一个修饰键（⌃/⌘/⌥/⇧）。"
                self.statusLabel.textColor = .systemRed
                self.hotkeyField.stringValue = hotkeyDisplayString(from: self.settings.hotkey)
                return
            }
            if let value {
                self.settings.hotkey = value
                self.hotkeyField.stringValue = hotkeyDisplayString(from: value)
                self.persistChanges()
            } else {
                self.hotkeyField.stringValue = hotkeyDisplayString(from: self.settings.hotkey)
                self.hotkeyRecordButton.title = "录制"
                self.hotkeyRecordButton.isEnabled = true
            }
        }
        hotkeyRecordButton.target = self
        hotkeyRecordButton.action = #selector(startHotkeyRecording)
        hotkeyRow.addArrangedSubview(hotkeyLabel)
        hotkeyRow.addArrangedSubview(hotkeyField)
        hotkeyRow.addArrangedSubview(hotkeyRecordButton)
        stack.addArrangedSubview(hotkeyRow)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "点击“录制”，然后直接按新的组合键；不允许无修饰键。"
        stack.addArrangedSubview(statusLabel)

        [apiKeyField, secretKeyField, saveDirField].forEach { $0.delegate = self }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .left
        return label
    }

    private func makeRow(label text: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let label = makeLabel(text)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return row
    }

    private func fillValues() {
        apiKeyField.stringValue = settings.apiKey
        secretKeyField.stringValue = settings.secretKey
        saveDirField.stringValue = settings.saveDirectory
        hotkeyField.stringValue = hotkeyDisplayString(from: settings.hotkey)
    }

    /// NOTE: 窗口重新打开时刷新最新的设置值，避免显示过期数据
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        fillValues()
        statusLabel.stringValue = ""
    }

    @objc private func startHotkeyRecording() {
        hotkeyField.beginRecording()
        window?.makeFirstResponder(hotkeyField)
        statusLabel.stringValue = "正在录制热键，按 Esc 取消。"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDirField.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirField.stringValue = url.path
            persistChanges()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // NOTE: 防抖 0.5 秒，避免每次按键都触发加密保存和热键重注册
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.persistChanges()
        }
    }

    private func persistChanges() {
        settings.apiKey = apiKeyField.stringValue
        settings.secretKey = secretKeyField.stringValue
        settings.saveDirectory = saveDirField.stringValue.isEmpty ? defaultSaveDirectory.path : saveDirField.stringValue
        let newHotkey = settings.hotkey.isEmpty ? "control+p" : settings.hotkey
        settings.hotkey = newHotkey
        do {
            try SecureSettingsStore.shared.save(settings)
            onSettingsChanged?(settings)
            if HotkeyParser.parse(newHotkey) == nil {
                statusLabel.stringValue = "热键格式无效。"
                statusLabel.textColor = .systemRed
            } else {
                hotkeyField.stringValue = hotkeyDisplayString(from: newHotkey)
                hotkeyRecordButton.title = "录制"
                hotkeyRecordButton.isEnabled = true
                statusLabel.stringValue = "已保存。设置立即生效。"
                statusLabel.textColor = .systemGreen
            }
        } catch {
            statusLabel.stringValue = "保存失败：\(error)"
            statusLabel.textColor = .systemRed
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SecureSettingsStore.shared
    private var settings: AppSettings!
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?
    private var overlayController: ScreenshotOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = settingsStore.load()
        ensureSaveDirectoryExists()
        setupStatusItem()
        applyHotkey()
        if settings.apiKey.isEmpty || settings.secretKey.isEmpty {
            showSettings(nil)
        }
    }

    private func ensureSaveDirectoryExists() {
        let url = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "表格OCR"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "截图识别", action: #selector(startCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开保存目录", action: #selector(openSaveDirectory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func applyHotkey() {
        let shortcut = HotkeyParser.parse(settings.hotkey) ?? HotkeyParser.parse("control+p")!
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.startCapture(nil)
        }
        HotKeyManager.shared.register(shortcut: shortcut)
    }

    @objc private func startCapture(_ sender: Any?) {
        // NOTE: 快速连续触发截图时，先清理旧的覆盖层和事件监听器
        overlayController?.cancel()
        overlayController = ScreenshotOverlayController()
        overlayController?.begin { [weak self] result in
            switch result {
            case .success(let data):
                OCRService.shared.recognizeTable(imageData: data, settings: self?.settings ?? AppSettings()) { result in
                    switch result {
                    case .success(let excelURL):
                        NSWorkspace.shared.activateFileViewerSelecting([excelURL])
                    case .failure(let error):
                        self?.showError(String(describing: error))
                    }
                }
            case .failure(let error):
                self?.showError(String(describing: error))
            }
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSettingsChanged = { [weak self] newSettings in
                self?.settings = newSettings
                self?.ensureSaveDirectoryExists()
                self?.applyHotkey()
            }
            settingsWindowController = controller
        } else {
            // NOTE: 窗口已存在时刷新为最新设置，避免显示过期数据
            settingsWindowController?.updateSettings(settings)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSaveDirectory(_ sender: Any?) {
        let url = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "表格识别失败"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
