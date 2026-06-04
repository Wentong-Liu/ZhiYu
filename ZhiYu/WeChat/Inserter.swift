import AppKit

/// 候选落地：仅填入，或填入并发送。复用 Phase 1 验证过的 InserterProbe。
@MainActor
enum Inserter {
    /// 仅填入微信输入框。
    @discardableResult
    static func fill(_ text: String) -> Bool {
        InserterProbe.setText(text)
    }

    /// 填入并发送：AX 写入 → 激活微信 + 聚焦 composer → 校验前台/焦点后回车。
    /// 返回是否已发出回车（写入失败或前台/焦点校验不过则不回车，返回 false）。
    static func fillAndSend(_ text: String, completion: @escaping (Bool) -> Void) {
        let ok = InserterProbe.setText(text)
        _ = InserterProbe.focusComposerAndActivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let written = InserterProbe.composerValue() ?? ""
            guard ok, written.contains(text), InserterProbe.isWeChatFrontFocused() else {
                completion(false); return
            }
            InserterProbe.sendReturn()
            completion(true)
        }
    }

    /// 把多条气泡逐条单独发出（每条之间留间隔，给微信处理时间）。
    static func sendSequential(_ parts: [String]) {
        sendNext(parts, 0)
    }

    private static func sendNext(_ parts: [String], _ i: Int) {
        guard i < parts.count else { return }
        let text = parts[i]
        guard !text.isEmpty else { sendNext(parts, i + 1); return }
        fillAndSend(text) { _ in
            // 上一条发出后留 0.4s 再发下一条（叠加 fillAndSend 内部时序，约 0.8s/条）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sendNext(parts, i + 1)
            }
        }
    }
}
