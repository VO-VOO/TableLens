import Foundation

let appServiceName = "TableLens"
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

enum AppFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}
