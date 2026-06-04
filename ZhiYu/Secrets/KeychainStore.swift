import Foundation
import Security

/// 极简 Keychain 读写（generic password）。Phase 2 仅存 OpenAI API Key。
enum KeychainStore {
    static let service = "com.liuwentong.ZhiYu"
    static let openAIKeyAccount = "openai.apiKey"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func openAIKey() -> String { get(account: openAIKeyAccount) ?? "" }
    static func setOpenAIKey(_ v: String) { set(v, account: openAIKeyAccount) }
}
