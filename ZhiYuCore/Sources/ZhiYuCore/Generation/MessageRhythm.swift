import Foundation

public enum MessageRhythm {
    /// 触发"多气泡"回复的对方连发条数阈值：末尾连续对方消息 >= 此值时，
    /// PromptBuilder 才指示模型用相近数量的简短消息（换行分隔）回应。
    public static let multiBubbleThreshold = 2

    /// 末尾连续"对方"消息的条数（对方最近连发了几条）。
    public static func trailingOtherCount(_ messages: [ChatMessage]) -> Int {
        var n = 0
        for m in messages.reversed() {
            if m.speaker == .other { n += 1 } else { break }
        }
        return n
    }
}
