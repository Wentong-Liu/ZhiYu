import Foundation

/// 微信本地化文案 / 占位串的单一真相源。
/// 这些字面量来自微信 AX 暴露的固定中文文案（如「发送了一个语音」「已转文字」）与本工程对外占位（如 `[语音]`）。
/// 在多处出现，统一收敛到此处避免漂移；改文案只动这一处。行为与原字面量完全一致。
public enum WeChatMarkers {
    /// 语音气泡的固定前缀文案。
    public static let sentVoice = "发送了一个语音"
    /// 语音「已转文字」标记，其后跟转写正文。
    public static let converted = "已转文字"
    /// 图片消息的固定文案。
    public static let sentImage = "发送了一个图片"
    /// 表情消息的固定文案。
    public static let sentSticker = "发送了一个表情"

    /// 语音占位（未转写时对外展示）。
    public static let voicePlaceholder = "[语音]"
    /// 图片占位。
    public static let imagePlaceholder = "[图片]"
    /// 表情占位。
    public static let stickerPlaceholder = "[表情]"
}
