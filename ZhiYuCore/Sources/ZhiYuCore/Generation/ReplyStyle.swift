import Foundation

/// 回复风格：预设或自定义。instruction 会拼进 system prompt。
/// 注意：「像真人、不客服」这条基础约束已在 PromptBuilder 的 system 里强制，
/// 这里的 instruction 只描述在此之上的额外风格倾向。
public struct ReplyStyle: Equatable, Sendable {
    public let name: String
    public let instruction: String
    public init(name: String, instruction: String) {
        self.name = name
        self.instruction = instruction
    }

    public static let natural  = ReplyStyle(name: "自然", instruction: "就用最自然随手的语气，别刻意。")
    public static let concise  = ReplyStyle(name: "简短", instruction: "尽量短，能一两个字或一句解决就不多说。")
    public static let buddy    = ReplyStyle(name: "损友", instruction: "像跟哥们或闺蜜，可以互相调侃、吐槽、损两句，别正经。")
    public static let humorous = ReplyStyle(name: "幽默", instruction: "带点梗和幽默，轻松但不尬不油。")
    public static let formal   = ReplyStyle(name: "正经", instruction: "同事或办正事的场景，得体一点，但仍然简短自然、不端着、不客服腔。")

    /// 展示与存取用的预设顺序；第一个是默认。
    public static let presets: [ReplyStyle] = [.natural, .concise, .buddy, .humorous, .formal]

    /// 默认风格：自然。
    public static let `default` = ReplyStyle.natural

    public static func custom(_ instruction: String) -> ReplyStyle {
        ReplyStyle(name: "自定义", instruction: instruction)
    }

    /// 按 name 取预设；不在预设里则回退到默认「自然」（兜底，不崩）。
    public static func preset(named name: String) -> ReplyStyle {
        presets.first { $0.name == name } ?? .default
    }
}
