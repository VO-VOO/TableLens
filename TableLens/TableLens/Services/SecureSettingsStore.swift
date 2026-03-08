import Foundation
import CryptoKit
import Security

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
