import Foundation

/// 回复风格：预设或自定义。instruction 会拼进 system prompt。
public struct ReplyStyle: Equatable, Sendable {
    public let name: String
    public let instruction: String
    public init(name: String, instruction: String) {
        self.name = name
        self.instruction = instruction
    }
    public static let concise  = ReplyStyle(name: "简洁", instruction: "回复简洁、口语化，通常不超过两句。")
    public static let friendly = ReplyStyle(name: "友好", instruction: "语气友好亲切、自然随和。")
    public static let formal   = ReplyStyle(name: "正式", instruction: "语气得体、礼貌、稳重。")
    public static let humorous = ReplyStyle(name: "幽默", instruction: "适度幽默、轻松，但不油腻。")
    public static let warm     = ReplyStyle(name: "热情", instruction: "热情、有温度、让人舒服。")
    public static let presets: [ReplyStyle] = [.concise, .friendly, .formal, .humorous, .warm]
    public static func custom(_ instruction: String) -> ReplyStyle {
        ReplyStyle(name: "自定义", instruction: instruction)
    }
}
