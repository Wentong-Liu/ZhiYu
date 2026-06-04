import Foundation
import ZhiYuCore

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case chatGPT = "ChatGPT 登录"
    var id: String { rawValue }

    /// 该 Provider 可选模型：(id 发给 API, label 展示)。
    var modelOptions: [(id: String, label: String)] {
        switch self {
        case .openAI:
            return [("gpt-5.5", "GPT-5.5"), ("gpt-5.4", "GPT-5.4"),
                    ("gpt-5.3", "GPT-5.3"), ("gpt-4o", "GPT-4o")]
        case .deepSeek:
            return [("deepseek-v4-flash", "Flash"), ("deepseek-v4-pro", "Pro")]
        case .chatGPT:
            return [("gpt-5.5", "GPT-5.5"), ("gpt-5.5-pro", "GPT-5.5 Pro"),
                    ("gpt-5.4", "GPT-5.4"), ("gpt-5.4-pro", "GPT-5.4 Pro"),
                    ("gpt-5.4-mini", "GPT-5.4 mini")]
        }
    }
    var defaultModel: String { modelOptions.first?.id ?? "" }
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
        // 夹回到当前 Provider 的可选模型：持久化的 model 若不属于当前 providerKind
        // （例如换过 Provider 但没点过模型下拉），回落到该 Provider 的默认模型，
        // 避免把不属于该 Provider 的 model id 发给 API。
        get {
            let stored = d.string(forKey: "model")
            let valid = providerKind.modelOptions.map(\.id)
            if let stored, valid.contains(stored) { return stored }
            return providerKind.defaultModel
        }
        set { d.set(newValue, forKey: "model") }
    }
    var styleIndex: Int {
        get { d.integer(forKey: "styleIndex") }
        set { d.set(newValue, forKey: "styleIndex") }
    }

    /// 自定义提示词（风格选"自定义"时用）。
    var customPrompt: String {
        get { d.string(forKey: "customPrompt") ?? "" }
        set { d.set(newValue, forKey: "customPrompt") }
    }

    /// 新消息自动预生成候选、切到微信前台时弹出。默认开。
    var autoOnNewMessage: Bool {
        get { d.object(forKey: "autoOnNewMessage") == nil ? true : d.bool(forKey: "autoOnNewMessage") }
        set { d.set(newValue, forKey: "autoOnNewMessage") }
    }

    /// 当前风格：styleIndex 落在预设范围内取预设，否则取自定义提示词。
    func currentStyle() -> ReplyStyle {
        let presets = ReplyStyle.presets
        if styleIndex >= presets.count {
            let p = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplyStyle.custom(p.isEmpty ? "用自然、得体、口语化的语气回复。" : p)
        }
        return presets[max(0, min(styleIndex, presets.count - 1))]
    }

    /// 缓存区分用：Provider+模型 标签，如 "DeepSeek/deepseek-v4-flash"。
    var modelTag: String { "\(providerKind.rawValue)/\(model)" }
    /// 面板展示用：如 "DeepSeek · deepseek-v4-flash"。
    var providerLabel: String { "\(providerKind.rawValue) · \(model)" }
}
