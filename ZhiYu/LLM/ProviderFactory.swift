import Foundation
import ZhiYuCore

/// 由当前配置构造一个 LLMProvider。数据驱动：读 ProviderKind.transport / providerConfig / keychainAccount。
/// ChatGPT 走 OAuth token；其余走 Keychain key（OpenAI 发图、DeepSeek/智谱GLM/Kimi/MiniMax 纯文本、Anthropic 走 Anthropic API）。
@MainActor
enum ProviderFactory {
    static func make() async throws -> any LLMProvider {
        let cfg = AppConfig.shared
        let kind = cfg.providerKind

        switch kind.transport {
        case .openAICompatible(let sendsImages):
            let config = try keyedConfig(for: kind, model: cfg.model)
            return OpenAICompatibleProvider(config: config.config, apiKey: config.apiKey, sendsImages: sendsImages)
        case .anthropic:
            let config = try keyedConfig(for: kind, model: cfg.model)
            return AnthropicProvider(config: config.config, apiKey: config.apiKey)
        case .codexOAuth:
            guard let tokens = await CodexLoginService.shared.validTokens() else {
                throw ProviderError.missingAPIKey
            }
            return CodexResponsesProvider(accessToken: tokens.accessToken,
                                          accountId: tokens.accountId, model: cfg.model)
        }
    }

    /// 取该 Provider 的 ProviderConfig 与已修整的 Keychain key；key 为空抛 missingAPIKey。
    /// 仅用于走 Keychain 的（openAICompatible / anthropic）传输方式。
    private static func keyedConfig(for kind: ProviderKind, model: String)
        throws -> (config: ProviderConfig, apiKey: String) {
        let key = KeychainStore.apiKey(for: kind).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let config = kind.providerConfig(model: model) else {
            throw ProviderError.missingAPIKey
        }
        return (config, key)
    }
}
