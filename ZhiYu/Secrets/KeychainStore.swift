import Foundation
import Security
import ZhiYuCore

/// 极简 Keychain 读写（generic password）。存 OpenAI/DeepSeek API Key 与 ChatGPT OAuthTokens。
enum KeychainStore {
    static let service = "com.liuwentong.ZhiYu"
    static let openAIKeyAccount = "openai.apiKey"
    static let deepSeekKeyAccount = "deepseek.apiKey"
    static let chatGPTTokensAccount = "chatgpt.oauthTokens"

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

    static func deepSeekKey() -> String { get(account: deepSeekKeyAccount) ?? "" }
    static func setDeepSeekKey(_ v: String) { set(v, account: deepSeekKeyAccount) }

    static func saveChatGPTTokens(_ tokens: ZhiYuCore.OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        set(String(decoding: data, as: UTF8.self), account: chatGPTTokensAccount)
    }

    static func loadChatGPTTokens() -> ZhiYuCore.OAuthTokens? {
        guard let s = get(account: chatGPTTokensAccount), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZhiYuCore.OAuthTokens.self, from: data)
    }

    static func clearChatGPTTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatGPTTokensAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
