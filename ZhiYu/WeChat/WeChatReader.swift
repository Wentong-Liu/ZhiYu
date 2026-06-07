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
        /// 最近最多 2 条图片/表情消息的气泡 frame（AX 全局左上原点坐标，按时间顺序）。
        let imageFrames: [CGRect]
    }

    /// 单次 AX 探针：从同一个 ProbeResult 同时得到上下文与输入框 frame。读不到返回 nil。
    static func readSnapshot() -> Snapshot? {
        switch WeChatAXProbe.run() {
        case .failure:
            return nil
        case .success(let r):
            // 只收集对方消息(.other)的非空 imageFrame（图片/表情），取最近 2 个、保持时间顺序；
            // 避免把自己发的图当对方图喂模型。
            let frames = r.messages.compactMap { $0.speaker == .other ? $0.imageFrame : nil }
            let recent = frames.count > 2 ? Array(frames.suffix(2)) : frames
            return Snapshot(context: context(from: r), composerFrame: r.inputFrame, imageFrames: recent)
        }
    }

    /// 按 frame 列表异步截图，返回成功截到的 PNG data URL（失败的项被跳过）。
    static func captureImages(_ frames: [CGRect]) async -> [String] {
        var urls: [String] = []
        for f in frames {
            if let u = await ScreenCapturer.capture(globalRect: f) { urls.append(u) }
        }
        return urls
    }

    /// 把已截到的图片附到 context。
    static func context(_ base: ChatContext, withImages urls: [String]) -> ChatContext {
        ChatContext(contactName: base.contactName, messages: base.messages, draft: base.draft, imageDataURLs: urls)
    }

    /// 把探针结果映射为 ChatContext（时间/系统分隔行不进上下文）。
    private static func context(from r: WeChatAXProbe.ProbeResult) -> ChatContext {
        let msgs: [ChatMessage] = r.messages.compactMap { m in
            switch m.speaker {
            case .me:    return ChatMessage(speaker: .me, text: VoiceText.clean(m.text))
            case .other: return ChatMessage(speaker: .other, text: VoiceText.clean(m.text))
            case .separator: return nil   // 时间/系统分隔行不进上下文
            }
        }
        return ChatContext(contactName: r.contactName, messages: msgs, draft: r.draft)
    }
}
