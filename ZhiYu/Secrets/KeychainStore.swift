import Foundation
import Security
import ZhiYuCore

/// 极简 Keychain 读写（generic password）。存 OpenAI/DeepSeek API Key 与 ChatGPT OAuthTokens。
enum KeychainStore {
    static let service = "com.liuwentong.ZhiYu"
    static let openAIKeyAccount = "openai.apiKey"
    static let deepSeekKeyAccount = "deepseek.apiKey"
    static let chatGPTTokensAccount = "chatgpt.oauthTokens"

    /// 写入凭证。返回是否真正写入成功（SecItemAdd 的 OSStatus == errSecSuccess）。
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[KeychainStore] SecItemAdd 写入失败 account=\(account) status=\(status)")
        }
        return status == errSecSuccess
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
    @discardableResult
    static func setOpenAIKey(_ v: String) -> Bool { set(v, account: openAIKeyAccount) }

    static func deepSeekKey() -> String { get(account: deepSeekKeyAccount) ?? "" }
    @discardableResult
    static func setDeepSeekKey(_ v: String) -> Bool { set(v, account: deepSeekKeyAccount) }

    /// 写入 ChatGPT OAuth tokens。返回是否真正写入成功（编码失败或 Keychain 写入失败均为 false）。
    @discardableResult
    static func saveChatGPTTokens(_ tokens: ZhiYuCore.OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else {
            NSLog("[KeychainStore] saveChatGPTTokens 编码失败")
            return false
        }
        return set(String(decoding: data, as: UTF8.self), account: chatGPTTokensAccount)
    }

    static func loadChatGPTTokens() -> ZhiYuCore.OAuthTokens? {
        guard let s = get(account: chatGPTTokensAccount), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZhiYuCore.OAuthTokens.self, from: data)
    }

    /// 清除 ChatGPT tokens。返回是否成功（已删除或本就不存在均视为成功）。
    @discardableResult
    static func clearChatGPTTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatGPTTokensAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let ok = (status == errSecSuccess || status == errSecItemNotFound)
        if !ok {
            NSLog("[KeychainStore] clearChatGPTTokens 删除失败 status=\(status)")
        }
        return ok
    }
}
