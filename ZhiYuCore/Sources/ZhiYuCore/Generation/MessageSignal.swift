import Foundation

/// 判断"是否有等我回的新消息"与"会话指纹（去重/变化检测用）"。纯函数，便于测试。
public enum MessageSignal {
    /// 最后一条是否为对方发来（=轮到我回）。空会话为 false。
    public static func lastIsIncoming(_ ctx: ChatContext) -> Bool {
        ctx.messages.last?.speaker == .other
    }
    /// 会话指纹：消息数 + 最后一条说话人与文本。同一状态稳定、状态变化即变。
    public static func signature(_ ctx: ChatContext) -> String {
        guard let last = ctx.messages.last else { return "empty" }
        return "\(ctx.messages.count)|\(last.speaker.rawValue)|\(last.text)"
    }
}
