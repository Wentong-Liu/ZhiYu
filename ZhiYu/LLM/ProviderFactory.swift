import Foundation
import ZhiYuCore

/// 由当前配置构造一个 LLMProvider。ChatGPT 走 OAuth token；OpenAI/DeepSeek/Anthropic/智谱GLM/Kimi/MiniMax 走 Keychain key。
@MainActor
enum ProviderFactory {
    static func make() async throws -> any LLMProvider {
        let cfg = AppConfig.shared
        switch cfg.providerKind {
        case .openAI:
            let k = KeychainStore.openAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .openAI(model: cfg.model), apiKey: k, sendsImages: true)
        case .deepSeek:
            let k = KeychainStore.deepSeekKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .deepSeek(model: cfg.model), apiKey: k)
        case .anthropic:
            let k = KeychainStore.anthropicKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return AnthropicProvider(config: .anthropic(model: cfg.model), apiKey: k)
        case .glm:
            let k = KeychainStore.glmKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .glm(model: cfg.model), apiKey: k)
        case .kimi:
            let k = KeychainStore.kimiKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .kimi(model: cfg.model), apiKey: k)
        case .minimax:
            let k = KeychainStore.minimaxKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .minimax(model: cfg.model), apiKey: k)
        case .chatGPT:
            guard let tokens = await CodexLoginService.shared.validTokens() else {
                throw ProviderError.missingAPIKey
            }
            return CodexResponsesProvider(accessToken: tokens.accessToken,
                                          accountId: tokens.accountId, model: cfg.model)
        }
    }
}
