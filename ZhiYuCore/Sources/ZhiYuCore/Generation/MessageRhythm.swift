import Foundation

public enum MessageRhythm {
    /// 末尾连续"对方"消息的条数（对方最近连发了几条）。
    public static func trailingOtherCount(_ messages: [ChatMessage]) -> Int {
        var n = 0
        for m in messages.reversed() {
            if m.speaker == .other { n += 1 } else { break }
        }
        return n
    }
}
