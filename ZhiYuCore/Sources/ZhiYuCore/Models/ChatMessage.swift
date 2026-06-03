import Foundation

/// 一条聊天消息。
public struct ChatMessage: Codable, Equatable, Sendable {
    /// 说话人：自己或对方。
    public enum Speaker: String, Codable, Sendable {
        case me
        case other
    }

    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
