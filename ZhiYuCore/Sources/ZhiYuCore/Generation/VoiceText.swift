import Foundation

public enum VoiceText {
    /// 清理语音消息文本：
    /// - 含 "已转文字"：取其后的转写文本，去掉紧跟的冒号(半角:或全角：)与空白后 trim；非空则返回它。
    /// - 否则含 "发送了一个语音"：返回 "[语音]"。
    /// - 否则原样返回。
    /// 依赖微信固定文案「已转文字/发送了一个语音」做切割：这些字面量是微信 AX 暴露的固定提示词，
    /// 微信改文案则需同步 WeChatMarkers（converted/sentVoice 等）。
    public static func clean(_ text: String) -> String {
        if let range = text.range(of: WeChatMarkers.converted) {
            var transcript = String(text[range.upperBound...])
            transcript = String(transcript.drop {
                $0 == ":" || $0 == "：" || $0.isWhitespace
            })
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if text.contains(WeChatMarkers.sentVoice) {
            return WeChatMarkers.voicePlaceholder
        }
        if text.contains(WeChatMarkers.sentImage) {
            return WeChatMarkers.imagePlaceholder
        }
        if text.contains(WeChatMarkers.sentSticker) {
            return WeChatMarkers.stickerPlaceholder
        }
        return text
    }
}
