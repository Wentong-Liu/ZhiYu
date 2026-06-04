import Foundation

/// 一次回复生成所需的对话上下文。
public struct ChatContext: Codable, Equatable, Sendable {
    /// 当前聊天对象名称（窗口标题 / 会话名）。
    public let contactName: String
    /// 按时间顺序的可见消息。
    public let messages: [ChatMessage]
    /// 输入框中已有的草稿（可能为空）。
    public let draft: String
    /// 最近图片/表情的截图（base64 data URL），供视觉模型识别；无则空。
    public let imageDataURLs: [String]

    public init(contactName: String, messages: [ChatMessage], draft: String,
                imageDataURLs: [String] = []) {
        self.contactName = contactName
        self.messages = messages
        self.draft = draft
        self.imageDataURLs = imageDataURLs
    }
}
