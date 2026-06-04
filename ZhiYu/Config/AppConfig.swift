import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case chatGPT = "ChatGPT 登录"
    var id: String { rawValue }
}

/// 全局共享配置（非密钥项走 UserDefaults；密钥/token 仍在 Keychain）。
/// 探针生成面板与悬浮面板都读它，保证双击触发时用的是当前所选 Provider/模型/风格。
@MainActor
final class AppConfig {
    static let shared = AppConfig()
    private let d = UserDefaults.standard

    var providerKind: ProviderKind {
        get { ProviderKind(rawValue: d.string(forKey: "providerKind") ?? "") ?? .openAI }
        set { d.set(newValue.rawValue, forKey: "providerKind") }
    }
    var model: String {
        get { d.string(forKey: "model") ?? "gpt-4o" }
        set { d.set(newValue, forKey: "model") }
    }
    var styleIndex: Int {
        get { d.integer(forKey: "styleIndex") }
        set { d.set(newValue, forKey: "styleIndex") }
    }

    /// 缓存区分用：Provider+模型 标签，如 "DeepSeek/deepseek-v4-flash"。
    var modelTag: String { "\(providerKind.rawValue)/\(model)" }
    /// 面板展示用：如 "DeepSeek · deepseek-v4-flash"。
    var providerLabel: String { "\(providerKind.rawValue) · \(model)" }
}
