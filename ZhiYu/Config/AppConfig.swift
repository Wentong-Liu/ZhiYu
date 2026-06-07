import Foundation
import ZhiYuCore

/// 一个 Provider 的「传输方式」：决定 ProviderFactory 构造哪种 LLMProvider、是否发图。
/// 把原先散在 ProviderFactory 里的 6 个近同分支收敛成数据，由 ProviderKind.transport 描述。
enum ProviderTransport {
    /// OpenAI 兼容（chat/completions）。`sendsImages` 决定是否把图片发给模型。
    case openAICompatible(sendsImages: Bool)
    /// Anthropic messages API。
    case anthropic
    /// ChatGPT 订阅登录（Codex OAuth，走 token 而非 Keychain key）。
    case codexOAuth
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case glm = "智谱GLM"
    case kimi = "Kimi"
    case minimax = "MiniMax"
    case chatGPT = "ChatGPT 登录"
    var id: String { rawValue }

    // MARK: 单一 descriptor —— per-provider 元数据收口在此

    /// 该 Provider 的连接配置（name/baseURL/model）。chatGPT 走 OAuth，无静态 ProviderConfig，返回 nil。
    /// 复用 ZhiYuCore 里既有的 ProviderConfig 工厂，name/baseURL 保持完全一致（不另起字面量）。
    func providerConfig(model: String) -> ProviderConfig? {
        switch self {
        case .openAI:    return .openAI(model: model)
        case .deepSeek:  return .deepSeek(model: model)
        case .anthropic: return .anthropic(model: model)
        case .glm:       return .glm(model: model)
        case .kimi:      return .kimi(model: model)
        case .minimax:   return .minimax(model: model)
        case .chatGPT:   return nil
        }
    }

    /// 该 Provider 在 Keychain 里存 API Key 用的 account 名。chatGPT 走 OAuth token（另存），返回 nil。
    /// 字符串名是落盘账户名，**改了会读不到已存 Key**，必须与历史完全一致。
    var keychainAccount: String? {
        switch self {
        case .openAI:    return "openai.apiKey"
        case .deepSeek:  return "deepseek.apiKey"
        case .anthropic: return "anthropic.apiKey"
        case .glm:       return "glm.apiKey"
        case .kimi:      return "kimi.apiKey"
        case .minimax:   return "minimax.apiKey"
        case .chatGPT:   return nil
        }
    }

    /// 传输方式：ProviderFactory 据此选 Provider 类型与是否发图。
    /// openAI 发图（gpt-4o 系多模态）；deepSeek/glm/kimi/minimax 纯文本；anthropic 走 Anthropic；chatGPT 走 Codex OAuth。
    var transport: ProviderTransport {
        switch self {
        case .openAI:    return .openAICompatible(sendsImages: true)
        case .deepSeek, .glm, .kimi, .minimax: return .openAICompatible(sendsImages: false)
        case .anthropic: return .anthropic
        case .chatGPT:   return .codexOAuth
        }
    }

    /// 展示名单一真相源：6 个 key 型 Provider 直接取其 ProviderConfig.name（与 baseURL 同源，避免「智谱GLM」等重复字面量）；
    /// chatGPT 无 ProviderConfig，用其 rawValue（"ChatGPT 登录"）。SettingsView 标题、ProviderConfig.name 均由此派生。
    var displayName: String {
        providerConfig(model: "").map(\.name) ?? rawValue
    }

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
    private let defaults = UserDefaults.standard

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
        // 静默回落：落盘的是 ProviderKind.rawValue（中文/英文展示名）。
        // 改了 rawValue 字面量会让旧落盘值匹配不上，这里回落到 .openAI 即丢用户原选的 Provider 配置。
        get { ProviderKind(rawValue: defaults.string(forKey: Key.providerKind) ?? "") ?? .openAI }
        set { defaults.set(newValue.rawValue, forKey: Key.providerKind) }
    }
    var model: String {
        // 夹回到当前 Provider 的可选模型：持久化的 model 若不属于当前 providerKind
        // （例如换过 Provider 但没点过模型下拉），回落到该 Provider 的默认模型，
        // 避免把不属于该 Provider 的 model id 发给 API。
        get {
            let stored = defaults.string(forKey: Key.model)
            let valid = providerKind.modelOptions.map(\.id)
            if let stored, valid.contains(stored) { return stored }
            return providerKind.defaultModel
        }
        set { defaults.set(newValue, forKey: Key.model) }
    }
    var styleIndex: Int {
        get { defaults.integer(forKey: Key.styleIndex) }
        set { defaults.set(newValue, forKey: Key.styleIndex) }
    }

    /// 自定义提示词（风格选"自定义"时用）。
    var customPrompt: String {
        get { defaults.string(forKey: Key.customPrompt) ?? "" }
        set { defaults.set(newValue, forKey: Key.customPrompt) }
    }

    /// 新消息自动预生成候选、切到微信前台时弹出。默认开。
    var autoOnNewMessage: Bool {
        get { defaults.object(forKey: Key.autoOnNewMessage) == nil ? true : defaults.bool(forKey: Key.autoOnNewMessage) }
        set { defaults.set(newValue, forKey: Key.autoOnNewMessage) }
    }

    /// 唤起候选面板的「双击修饰键」。缺省双击右⌘；监听处实时读它，改了立即生效。
    var triggerKey: TriggerKey {
        // 静默回落：落盘的是 TriggerKey.rawValue。改了 rawValue 字面量会让旧落盘值匹配不上，
        // 这里回落到 .rightCommand 即丢用户原选的修饰键配置。
        get { TriggerKey(rawValue: defaults.string(forKey: Key.triggerKey) ?? "") ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerKey) }
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

    /// modelTag 里 Provider 与模型之间的分隔符（缓存键用，斜杠紧凑无空格）。
    private static let modelTagSeparator = "/"
    /// providerLabel 里 Provider 与模型之间的分隔符（展示用，中点带左右空格）。
    private static let providerLabelSeparator = " · "

    /// 缓存区分用：Provider+模型 标签，如 "DeepSeek/deepseek-v4-flash"。
    var modelTag: String { "\(providerKind.rawValue)\(Self.modelTagSeparator)\(model)" }
    /// 面板展示用：如 "DeepSeek · deepseek-v4-flash"。
    var providerLabel: String { "\(providerKind.rawValue)\(Self.providerLabelSeparator)\(model)" }
}
