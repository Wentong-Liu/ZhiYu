import AppKit
import ZhiYuCore

/// 读取微信当前会话为 ChatContext。复用探针验证过的快速 AX 读取。
@MainActor
enum WeChatReader {
    /// 一次 AX 读取的结果：会话上下文 + 输入框屏幕 frame（AX 左上原点坐标，可能为 nil）。
    /// 双击触发应只读一次，避免两次遍历观察到不一致的 UI 状态（会话切换后消息与输入框来自不同会话）。
    struct Snapshot {
        let context: ChatContext
        let composerFrame: CGRect?
    }

    /// 单次 AX 探针：从同一个 ProbeResult 同时得到上下文与输入框 frame。读不到返回 nil。
    static func readSnapshot() -> Snapshot? {
        switch WeChatAXProbe.run() {
        case .failure:
            return nil
        case .success(let r):
            return Snapshot(context: context(from: r), composerFrame: r.inputFrame)
        }
    }

    /// 返回当前会话上下文；读不到返回 nil。
    static func readCurrentContext() -> ChatContext? {
        readSnapshot()?.context
    }

    /// 当前会话输入框的屏幕 frame（AX 左上原点坐标），读不到返回 nil。
    static func composerFrame() -> CGRect? {
        readSnapshot()?.composerFrame
    }

    /// 把探针结果映射为 ChatContext（时间/系统分隔行不进上下文）。
    private static func context(from r: WeChatAXProbe.ProbeResult) -> ChatContext {
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
