import Foundation

actor TokenCacheStore {
    private var cachedToken: String?
    private var cachedTokenApiKey: String?
    private var cachedTokenSecretKey: String?
    private var tokenFetchTime: Date?

    func getValidToken(apiKey: String, secretKey: String, validDuration: TimeInterval) -> String? {
        guard let token = cachedToken,
              let fetchTime = tokenFetchTime,
              cachedTokenApiKey == apiKey,
              cachedTokenSecretKey == secretKey,
              Date().timeIntervalSince(fetchTime) < validDuration else {
            return nil
        }
        return token
    }

    func update(token: String, apiKey: String, secretKey: String) {
        cachedToken = token
        cachedTokenApiKey = apiKey
        cachedTokenSecretKey = secretKey
        tokenFetchTime = Date()
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
    private let tokenValidDuration: TimeInterval = 29 * 24 * 3600
    private let tokenCache = TokenCacheStore()

    func recognizeTable(imageData: Data, settings: AppSettings, completion: @escaping (Result<URL, Error>) -> Void) {
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let excelURL = try await self.recognizeTable(imageData: imageData, settings: settings)
                await MainActor.run { completion(.success(excelURL)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func recognizeTable(imageData: Data, settings: AppSettings) async throws -> URL {
        let accessToken = try await fetchAccessToken(apiKey: settings.apiKey, secretKey: settings.secretKey)
        let payload: [String: String] = [
            "image": imageData.base64EncodedString(),
            "return_excel": "true",
            "cell_contents": "true",
        ]
        var comps = URLComponents(string: self.tableURL)!
        comps.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        let json = try await requestJSON(url: comps.url!, body: payload)

        let saveDir = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let timestamp = Self.timestamp()
        let jsonURL = saveDir.appendingPathComponent("\(timestamp).json")
        let excelURL = saveDir.appendingPathComponent("\(timestamp).xlsx")

        if let errorCode = json["error_code"] {
            try self.writeJSONLog(json, to: jsonURL)
            throw AppFailure.message("Baidu OCR error: \(errorCode) \(json["error_msg"] ?? "")。日志：\(jsonURL.path)")
        }

        guard let excelBase64 = json["excel_file"] as? String,
              let excelData = Data(base64Encoded: excelBase64)
        else {
            try self.writeJSONLog(json, to: jsonURL)
            throw AppFailure.message("No excel_file returned. 日志：\(jsonURL.path)")
        }

        try excelData.write(to: excelURL)
        return excelURL
    }

    private func fetchAccessToken(apiKey: String, secretKey: String) async throws -> String {
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            throw AppFailure.message("请先在设置里填写百度 API Key 和 Secret Key。")
        }

        if let token = await tokenCache.getValidToken(apiKey: apiKey, secretKey: secretKey, validDuration: tokenValidDuration) {
            return token
        }

        var comps = URLComponents(string: tokenURL)!
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: secretKey),
        ]
        let json = try await requestRawJSON(url: comps.url!, method: "POST", headers: ["Content-Type": "application/json"], body: nil)
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw AppFailure.message("获取 access_token 失败。")
        }

        await tokenCache.update(token: token, apiKey: apiKey, secretKey: secretKey)
        return token
    }

    private func requestJSON(url: URL, body: [String: String]) async throws -> [String: Any] {
        let encoded = body.map { key, value -> String in
            let k = Self.formEncode(key)
            let v = Self.formEncode(value)
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return try await requestRawJSON(url: url, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        ], body: Data(encoded.utf8))
    }

    private func requestRawJSON(url: URL, method: String, headers: [String: String], body: Data?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (resultData, _) = try await session.data(for: request)
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

    private func writeJSONLog(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
