import Foundation

/// 一个大模型 Provider 的连接配置（name/baseURL/model）。API Key 不放这里，调用时传入。
public struct ProviderConfig: Equatable, Sendable {
    public let name: String
    public let baseURL: String   // 形如 "https://api.openai.com/v1"
    public let model: String
    public init(name: String, baseURL: String, model: String) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }
    public static func openAI(model: String) -> ProviderConfig {
        ProviderConfig(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: model)
    }
    public static func deepSeek(model: String) -> ProviderConfig {
        ProviderConfig(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: model)
    }
    public static func anthropic(model: String) -> ProviderConfig {
        ProviderConfig(name: "Anthropic", baseURL: "https://api.anthropic.com/v1", model: model)
    }
    public static func glm(model: String) -> ProviderConfig {
        ProviderConfig(name: "智谱GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: model)
    }
    public static func kimi(model: String) -> ProviderConfig {
        ProviderConfig(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: model)
    }
    public static func minimax(model: String) -> ProviderConfig {
        ProviderConfig(name: "MiniMax", baseURL: "https://api.minimaxi.com/v1", model: model)
    }
}
