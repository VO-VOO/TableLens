#!/usr/bin/env swift

import Foundation

let tokenURL = "https://aip.baidubce.com/oauth/2.0/token"
let defaultTableURL = "https://aip.baidubce.com/rest/2.0/ocr/v1/table"
let imageSuffixes: Set<String> = ["jpg", "jpeg", "png", "bmp"]
let defaultOutputDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Desktop")
    .appendingPathComponent("表格识别")

struct Config {
    var apiKey: String = ""
    var secretKey: String = ""
    var accessToken: String = ""
    var tableURL: String = defaultTableURL
    var inputFile: String = ""
    var inputURL: String = ""
    var pageNum: Int? = 1
    var returnExcel: Bool = true
    var cellContents: Bool = true
    var outputDir: String = "~/Desktop/表格识别"
    var outputJSON: String = ""
    var outputExcel: String = ""
    var useNativeScreenshot: Bool = true
}

enum AppError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let msg): return msg
        }
    }
}

func expandPath(_ raw: String) -> URL {
    let expanded = (raw as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded)
}

func loadEnvFile(_ path: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) else {
        return [:]
    }
    var result: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \ .isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || !line.contains("=") { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = value
    }
    return result
}

func boolValue(_ raw: String?, default defaultValue: Bool) -> Bool {
    guard let raw else { return defaultValue }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on": return true
    case "0", "false", "no", "n", "off": return false
    default: return defaultValue
    }
}

func nowTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter.string(from: Date())
}

func requestJSON(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 120
    request.httpBody = body
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?

    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        resultData = data
        resultError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let resultError { throw resultError }
    guard let resultData else { throw AppError.message("No response data") }
    let obj = try JSONSerialization.jsonObject(with: resultData)
    guard let json = obj as? [String: Any] else {
        throw AppError.message("Response is not a JSON object")
    }
    return json
}

func getAccessToken(apiKey: String, secretKey: String) throws -> String {
    var comps = URLComponents(string: tokenURL)!
    comps.queryItems = [
        URLQueryItem(name: "grant_type", value: "client_credentials"),
        URLQueryItem(name: "client_id", value: apiKey),
        URLQueryItem(name: "client_secret", value: secretKey)
    ]
    let json = try requestJSON(
        url: comps.url!,
        method: "POST",
        headers: ["Content-Type": "application/json", "Accept": "application/json"]
    )
    if let token = json["access_token"] as? String, !token.isEmpty {
        return token
    }
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    throw AppError.message("Failed to get access_token: \n\(String(data: data, encoding: .utf8) ?? "")")
}

func nativeCaptureToTempFile() throws -> URL {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let output = tempDir.appendingPathComponent("baidu_table_capture_\(nowTimestamp()).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-r", output.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw AppError.message("Screenshot was cancelled or failed.")
    }
    guard FileManager.default.fileExists(atPath: output.path) else {
        throw AppError.message("Screenshot file was not created.")
    }
    return output
}

func resolveOutputPaths(config: Config, timestamp: String) throws -> (dir: URL, json: URL, excel: URL) {
    let outputDir = config.outputDir.isEmpty ? defaultOutputDir : expandPath(config.outputDir)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let jsonURL: URL = config.outputJSON.isEmpty
        ? outputDir.appendingPathComponent("\(timestamp).json")
        : expandPath(config.outputJSON)
    let excelURL: URL = config.outputExcel.isEmpty
        ? outputDir.appendingPathComponent("\(timestamp).xlsx")
        : expandPath(config.outputExcel)

    try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: excelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (outputDir, jsonURL, excelURL)
}

func buildPayload(inputFile: URL?, inputURL: String?, pageNum: Int?, returnExcel: Bool, cellContents: Bool) throws -> [String: String] {
    var payload: [String: String] = [
        "return_excel": returnExcel ? "true" : "false",
        "cell_contents": cellContents ? "true" : "false"
    ]

    if let inputURL, !inputURL.isEmpty {
        payload["url"] = inputURL
        return payload
    }

    guard let inputFile else {
        throw AppError.message("Please provide BAIDU_OCR_INPUT_FILE / BAIDU_OCR_INPUT_URL, or use native screenshot mode.")
    }
    let path = inputFile.path
    guard FileManager.default.fileExists(atPath: path) else {
        throw AppError.message("Input file not found: \(path)")
    }

    let ext = inputFile.pathExtension.lowercased()
    let raw = try Data(contentsOf: inputFile).base64EncodedString()
    if imageSuffixes.contains(ext) {
        payload["image"] = raw
    } else if ext == "pdf" {
        payload["pdf_file"] = raw
        if let pageNum { payload["pdf_file_num"] = String(pageNum) }
    } else if ext == "ofd" {
        payload["ofd_file"] = raw
        if let pageNum { payload["ofd_file_num"] = String(pageNum) }
    } else {
        throw AppError.message("Unsupported input suffix: .\(ext)")
    }
    return payload
}

func saveJSON(_ json: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func saveExcelIfPresent(_ json: [String: Any], to url: URL) throws -> Bool {
    guard let excel = json["excel_file"] as? String, !excel.isEmpty else { return false }
    guard let data = Data(base64Encoded: excel) else {
        throw AppError.message("excel_file is not valid base64")
    }
    try data.write(to: url)
    return true
}

func parseConfig() -> Config {
    var config = Config()
    let envFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
    let fileValues = loadEnvFile(envFile)
    let env = ProcessInfo.processInfo.environment

    func value(_ key: String) -> String? {
        if let v = env[key], !v.isEmpty { return v }
        if let v = fileValues[key], !v.isEmpty { return v }
        return nil
    }

    config.apiKey = value("BAIDU_OCR_API_KEY") ?? ""
    config.secretKey = value("BAIDU_OCR_SECRET_KEY") ?? ""
    config.accessToken = value("BAIDU_OCR_ACCESS_TOKEN") ?? ""
    config.tableURL = value("BAIDU_OCR_TABLE_URL") ?? defaultTableURL
    config.inputFile = value("BAIDU_OCR_INPUT_FILE") ?? ""
    config.inputURL = value("BAIDU_OCR_INPUT_URL") ?? ""
    if let p = value("BAIDU_OCR_PAGE_NUM"), let i = Int(p) { config.pageNum = i }
    config.returnExcel = boolValue(value("BAIDU_OCR_RETURN_EXCEL"), default: true)
    config.cellContents = boolValue(value("BAIDU_OCR_CELL_CONTENTS"), default: true)
    config.outputDir = value("BAIDU_OCR_OUTPUT_DIR") ?? "~/Desktop/表格识别"
    config.outputJSON = value("BAIDU_OCR_OUTPUT_JSON") ?? ""
    config.outputExcel = value("BAIDU_OCR_OUTPUT_EXCEL") ?? ""
    config.useNativeScreenshot = boolValue(value("BAIDU_OCR_USE_NATIVE_SCREENSHOT"), default: true)
    return config
}

func formURLEncode(_ string: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    return string
        .addingPercentEncoding(withAllowedCharacters: allowed)?
        .replacingOccurrences(of: "%20", with: "+") ?? string
}

func makeFormBody(_ payload: [String: String]) -> Data {
    let form = payload.map { key, value in
        let k = formURLEncode(key)
        let v = formURLEncode(value)
        return "\(k)=\(v)"
    }.joined(separator: "&")
    return Data(form.utf8)
}

func main() throws {
    var config = parseConfig()
    let timestamp = nowTimestamp()
    let outputs = try resolveOutputPaths(config: config, timestamp: timestamp)

    var tempCapture: URL?
    var inputFileURL: URL?
    if !config.inputFile.isEmpty {
        inputFileURL = expandPath(config.inputFile)
    } else if config.inputURL.isEmpty && config.useNativeScreenshot {
        print("未提供输入文件，启动 macOS 原生截图…")
        tempCapture = try nativeCaptureToTempFile()
        inputFileURL = tempCapture
    }

    let accessToken: String
    if !config.accessToken.isEmpty {
        accessToken = config.accessToken
    } else {
        guard !config.apiKey.isEmpty, !config.secretKey.isEmpty else {
            throw AppError.message("Missing credentials: set BAIDU_OCR_API_KEY + BAIDU_OCR_SECRET_KEY, or BAIDU_OCR_ACCESS_TOKEN.")
        }
        accessToken = try getAccessToken(apiKey: config.apiKey, secretKey: config.secretKey)
    }

    let payload = try buildPayload(
        inputFile: inputFileURL,
        inputURL: config.inputURL.isEmpty ? nil : config.inputURL,
        pageNum: config.pageNum,
        returnExcel: config.returnExcel,
        cellContents: config.cellContents
    )

    var comps = URLComponents(string: config.tableURL)!
    comps.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]

    let json = try requestJSON(
        url: comps.url!,
        method: "POST",
        headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json"
        ],
        body: makeFormBody(payload)
    )

    try saveJSON(json, to: outputs.json)
    let excelSaved = try saveExcelIfPresent(json, to: outputs.excel)

    print("Baidu Table OCR request finished.")
    print("- output json: \(outputs.json.path)")
    if excelSaved {
        print("- output excel: \(outputs.excel.path)")
    } else if config.returnExcel {
        print("- excel_file not present in response")
    }
    if let logId = json["log_id"] { print("- log_id: \(logId)") }
    if let tableNum = json["table_num"] { print("- table_num: \(tableNum)") }

    if let errorCode = json["error_code"] {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        throw AppError.message("Baidu OCR returned error_code=\(errorCode)")
    }

    if let tempCapture {
        try? FileManager.default.removeItem(at: tempCapture)
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(1)
}
