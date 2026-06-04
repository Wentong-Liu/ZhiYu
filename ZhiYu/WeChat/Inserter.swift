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
}
