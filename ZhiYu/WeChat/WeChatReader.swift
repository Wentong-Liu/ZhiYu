import AppKit
import ZhiYuCore

/// 读取微信当前会话为 ChatContext。复用探针验证过的快速 AX 读取。
@MainActor
enum WeChatReader {
    /// 返回当前会话上下文；读不到返回 nil。
    static func readCurrentContext() -> ChatContext? {
        switch WeChatAXProbe.run() {
        case .failure:
            return nil
        case .success(let r):
            let msgs: [ChatMessage] = r.messages.compactMap { m in
                switch m.speaker {
                case .me:    return ChatMessage(speaker: .me, text: m.text)
                case .other: return ChatMessage(speaker: .other, text: m.text)
                case .separator: return nil   // 时间/系统分隔行不进上下文
                }
            }
            return ChatContext(contactName: r.contactName, messages: msgs, draft: r.draft)
        }
    }
}
