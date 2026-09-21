import Foundation
import Security

/// API キーを macOS キーチェーンに保存する。
public enum KeychainStore {
    public static let service = "com.ictcacao.CacaoTrans"
    public static let apiKeyAccount = "anthropic-api-key"

    public static func loadAPIKey() -> String? {
        load(account: apiKeyAccount)
    }

    public static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: apiKeyAccount)
        } else {
            try save(account: apiKeyAccount, value: trimmed)
        }
    }

    /// 環境変数 → キーチェーンの順で探す（CLI とアプリで共通）。
    public static func resolveAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return loadAPIKey()
    }

    // MARK: - Generic

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .status(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "\(s)"
            return "キーチェーンへの保存に失敗しました: \(msg)"
        }
    }
}
