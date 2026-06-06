import Foundation
import ZhiYuCore

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case glm = "智谱GLM"
    case kimi = "Kimi"
    case minimax = "MiniMax"
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
        case .anthropic:
            return [("claude-sonnet-4-6", "Claude Sonnet 4.6"),
                    ("claude-opus-4-8", "Claude Opus 4.8"),
                    ("claude-haiku-4-5-20251001", "Claude Haiku 4.5")]
        case .glm:
            return [("glm-4-flash", "GLM-4-Flash"), ("glm-4-plus", "GLM-4-Plus"),
                    ("glm-4-air", "GLM-4-Air"), ("glm-4.6", "GLM-4.6")]
        case .kimi:
            return [("moonshot-v1-8k", "Moonshot v1 8K"), ("moonshot-v1-32k", "Moonshot v1 32K"),
                    ("moonshot-v1-128k", "Moonshot v1 128K"), ("kimi-latest", "Kimi Latest")]
        case .minimax:
            return [("MiniMax-M2", "MiniMax-M2"), ("MiniMax-M2.5", "MiniMax-M2.5"),
                    ("MiniMax-M3", "MiniMax-M3")]
        case .chatGPT:
            return [("gpt-5.5", "GPT-5.5"), ("gpt-5.5-pro", "GPT-5.5 Pro"),
                    ("gpt-5.4", "GPT-5.4"), ("gpt-5.4-pro", "GPT-5.4 Pro"),
                    ("gpt-5.4-mini", "GPT-5.4 mini")]
        }
    }
    var defaultModel: String { modelOptions.first?.id ?? "" }

    /// 该 Provider 在本 App 内是否会把图片发给模型（即能否识别图片/表情包）。
    /// Anthropic、ChatGPT、OpenAI（gpt-4o 系，走 OpenAICompatibleProvider 发图）会发送图片；
    /// DeepSeek / 智谱GLM / Kimi / MiniMax 默认模型是纯文本，只发文本。
    var supportsMultimodal: Bool {
        switch self {
        case .anthropic, .chatGPT, .openAI: return true
        case .deepSeek, .glm, .kimi, .minimax: return false
        }
    }
}

/// 全局共享配置（非密钥项走 UserDefaults；密钥/token 仍在 Keychain）。
/// 探针生成面板与悬浮面板都读它，保证双击触发时用的是当前所选 Provider/模型/风格。
@MainActor
final class AppConfig {
    static let shared = AppConfig()
    private let d = UserDefaults.standard

    /// 持久化用的 UserDefaults 键。字符串值是落盘键名，**改了会丢已有配置**，不可变。
    private enum Key {
        static let providerKind = "providerKind"
        static let model = "model"
        static let styleIndex = "styleIndex"
        static let customPrompt = "customPrompt"
        static let autoOnNewMessage = "autoOnNewMessage"
        static let triggerKey = "triggerKey"
    }

    var providerKind: ProviderKind {
        get { ProviderKind(rawValue: d.string(forKey: Key.providerKind) ?? "") ?? .openAI }
        set { d.set(newValue.rawValue, forKey: Key.providerKind) }
    }
    var model: String {
        // 夹回到当前 Provider 的可选模型：持久化的 model 若不属于当前 providerKind
        // （例如换过 Provider 但没点过模型下拉），回落到该 Provider 的默认模型，
        // 避免把不属于该 Provider 的 model id 发给 API。
        get {
            let stored = d.string(forKey: Key.model)
            let valid = providerKind.modelOptions.map(\.id)
            if let stored, valid.contains(stored) { return stored }
            return providerKind.defaultModel
        }
        set { d.set(newValue, forKey: Key.model) }
    }
    var styleIndex: Int {
        get { d.integer(forKey: Key.styleIndex) }
        set { d.set(newValue, forKey: Key.styleIndex) }
    }

    /// 自定义提示词（风格选"自定义"时用）。
    var customPrompt: String {
        get { d.string(forKey: Key.customPrompt) ?? "" }
        set { d.set(newValue, forKey: Key.customPrompt) }
    }

    /// 新消息自动预生成候选、切到微信前台时弹出。默认开。
    var autoOnNewMessage: Bool {
        get { d.object(forKey: Key.autoOnNewMessage) == nil ? true : d.bool(forKey: Key.autoOnNewMessage) }
        set { d.set(newValue, forKey: Key.autoOnNewMessage) }
    }

    /// 唤起候选面板的「双击修饰键」。缺省双击右⌘；监听处实时读它，改了立即生效。
    var triggerKey: TriggerKey {
        get { TriggerKey(rawValue: d.string(forKey: Key.triggerKey) ?? "") ?? .rightCommand }
        set { d.set(newValue.rawValue, forKey: Key.triggerKey) }
    }

    /// 当前风格：styleIndex 落在预设范围内取预设，否则取自定义提示词。
    /// 预设按 name 解析并兜底——存的索引/名字若不在新 presets 里，回退到默认「自然」，不崩。
    func currentStyle() -> ReplyStyle {
        let presets = ReplyStyle.presets
        if styleIndex >= presets.count {
            let p = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplyStyle.custom(p.isEmpty ? "就用最自然随手的语气回复，别刻意。" : p)
        }
        guard styleIndex >= 0, styleIndex < presets.count else { return .default }
        return ReplyStyle.preset(named: presets[styleIndex].name)
    }

    /// 缓存区分用：Provider+模型 标签，如 "DeepSeek/deepseek-v4-flash"。
    var modelTag: String { "\(providerKind.rawValue)/\(model)" }
    /// 面板展示用：如 "DeepSeek · deepseek-v4-flash"。
    var providerLabel: String { "\(providerKind.rawValue) · \(model)" }
}
