import Foundation
import Security
import ZhiYuCore

/// 极简 Keychain 读写（generic password）。存各 Provider 的 API Key（OpenAI/DeepSeek/Anthropic/GLM/Kimi/MiniMax）与 ChatGPT OAuthTokens。
enum KeychainStore {
    static let service = "com.liuwentong.ZhiYu"
    static let chatGPTTokensAccount = "chatgpt.oauthTokens"

    /// 写入凭证。非破坏写：先 SecItemUpdate（成功即返回 true）；不存在时再 SecItemAdd。
    /// 不先 SecItemDelete，避免写入失败时丢掉旧值。返回是否真正写入成功。
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 1) 先尝试更新现有项（仅改 kSecValueData）。
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // 2) 不存在则新增（带完整属性）。
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[KeychainStore] SecItemAdd 写入失败 account=\(account) status=\(addStatus)")
            }
            return addStatus == errSecSuccess
        }
        // 3) 其它错误：保留旧值、返回失败。
        NSLog("[KeychainStore] SecItemUpdate 写入失败 account=\(account) status=\(updateStatus)")
        return false
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

    /// 统一入口：按 ProviderKind 读 API Key。account 名取自 ProviderKind.keychainAccount（单一真相源）。
    /// chatGPT 走 OAuth token（saveChatGPTTokens / loadChatGPTTokens），无 API Key，返回空串。
    static func apiKey(for kind: ProviderKind) -> String {
        guard let account = kind.keychainAccount else { return "" }
        return get(account: account) ?? ""
    }

    /// 统一入口：按 ProviderKind 写 API Key。返回是否真正写入成功。
    /// chatGPT 无 API Key，直接视为成功（不写）。
    @discardableResult
    static func setAPIKey(_ v: String, for kind: ProviderKind) -> Bool {
        guard let account = kind.keychainAccount else { return true }
        return set(v, account: account)
    }

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
