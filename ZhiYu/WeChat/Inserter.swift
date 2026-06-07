import AppKit

/// 候选落地：仅填入，或填入并发送。复用 Phase 1 验证过的 InserterProbe。
@MainActor
enum Inserter {
    /// 发送前轮询输入框就绪的间隔（约 60ms 一次）。
    private static let readinessPollInterval: TimeInterval = 0.06
    /// 发送前轮询的总超时（超过仍不就绪则放弃回车，约 1.5s）。
    private static let readinessTimeout: TimeInterval = 1.5
    /// 回车后轮询确认 composer 已清空（=微信真发出）的总超时。取够宽：真发出后 composer
    /// 几乎瞬间清空；宽超时避免「真发了但清慢了」被误判失败而漏掉后面几条。
    private static let sendConfirmTimeout: TimeInterval = 1.5
    /// 回车 post 后先让微信处理一次键盘事件，再开始 AX 读取确认，避免确认读值抢在发送处理之前。
    private static let sendConfirmInitialDelay: TimeInterval = 0.2
    /// 逐条发送时，上一条发出后到发下一条之间的间隔（叠加 fillAndSend 内部时序，约 0.8s/条）。
    private static let sequentialSendGap: TimeInterval = 0.4

    /// 仅填入微信输入框。
    @discardableResult
    static func fill(_ text: String) -> Bool {
        InserterProbe.setText(text)
    }

    /// 填入并发送：AX 写入 → 激活微信 + 聚焦 composer → 轮询输入框就绪后回车。
    /// 就绪判据：composer 内容（trim 后）包含目标文本（trim 后）且微信已在前台/焦点。
    /// 不再固定死等 0.4s，而是每约 60ms 轮询一次，就绪即发；到超时仍不就绪返回 false。
    /// 返回是否已发出回车（写入失败或始终不就绪则不回车，返回 false）。
    static func fillAndSend(_ text: String, completion: @escaping (Bool) -> Void) {
        let ok = InserterProbe.setText(text)
        // 定位不到 composer 时 focusComposerAndActivate 返回 false：聚焦失败过去静默忽略，现补日志。
        // 不改正常流程（成功路径行为不变，仍继续轮询发送）。
        if !InserterProbe.focusComposerAndActivate() {
            NSLog("[ZhiYu] fillAndSend 聚焦失败：定位不到 composer（仅微信切前台），将靠前台/既有焦点兜底")
        }
        guard ok else { completion(false); return }
        pollUntilReady(text, deadline: .now() + readinessTimeout, completion: completion)
    }

    /// 递归轮询：就绪即 sendReturn + completion(true)；超时则 completion(false)。
    private static func pollUntilReady(_ text: String,
                                       deadline: DispatchTime,
                                       completion: @escaping (Bool) -> Void) {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = (InserterProbe.composerValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if written.contains(target), InserterProbe.isWeChatFrontFocused() {
            // CGEvent post 失败（回车没投出去）直接 false，让逐条发送停止后续以免覆盖/乱序。
            guard InserterProbe.sendReturn() else { completion(false); return }
            // post 成功 ≠ 微信真发出：紧跟 activate()、键盘焦点没落稳时回车可能被忽略，
            // 第一条只是短暂出现在 composer。故再轮询确认 composer 清空（=真发出）才算成功，
            // 超时仍在则 false 停后续，避免下一条 setText 覆盖首条导致首条丢失。
            DispatchQueue.main.asyncAfter(deadline: .now() + sendConfirmInitialDelay) {
                pollUntilSent(text, deadline: .now() + sendConfirmTimeout, completion: completion)
            }
            return
        }
        guard DispatchTime.now() < deadline else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollInterval) {
            pollUntilReady(text, deadline: deadline, completion: completion)
        }
    }

    /// 递归轮询确认「微信已真把这条发出去」：composer（trim 后）不再 contains 目标（trim 后）
    /// 即视为已清空发出 → completion(true)；超时仍含目标 → completion(false)（没真发出，停后续）。
    private static func pollUntilSent(_ text: String,
                                      deadline: DispatchTime,
                                      completion: @escaping (Bool) -> Void) {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = InserterProbe.composerValue() else {
            guard DispatchTime.now() < deadline else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollInterval) {
                pollUntilSent(text, deadline: deadline, completion: completion)
            }
            return
        }
        let current = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.contains(target) {
            completion(true)
            return
        }
        guard DispatchTime.now() < deadline else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollInterval) {
            pollUntilSent(text, deadline: deadline, completion: completion)
        }
    }

    /// 把多条气泡逐条单独发出（每条之间留间隔，给微信处理时间）。
    static func sendSequential(_ parts: [String], targetContact: String?) {
        sendNext(parts, 0, targetContact)
    }

    private static func sendNext(_ parts: [String], _ i: Int, _ targetContact: String?) {
        guard i < parts.count else { return }
        let text = parts[i]
        guard !text.isEmpty else { sendNext(parts, i + 1, targetContact); return }
        // 每条发送前校验会话身份：会话已切换则停止，避免把后续气泡发到别的会话。默认放行(isCurrentContact 内部处理)。
        guard WeChatAXProbe.isCurrentContact(targetContact) else {
            NSSound.beep(); NSLog("[ZhiYu] sendSequential 第 %d/%d 条前检测到会话已切换，停止发送", i + 1, parts.count); return
        }
        fillAndSend(text) { ok in
            // 这一条没发出（false）：若继续 setText 下一条会覆盖 composer 导致漏发/乱序，故停止剩余逐条发送。
            guard ok else {
                NSSound.beep()
                NSLog("[ZhiYu] sendSequential 第 %d/%d 条未发出，停止后续以避免覆盖/乱序", i + 1, parts.count)
                return
            }
            // 上一条发出后留 sequentialSendGap 再发下一条。
            DispatchQueue.main.asyncAfter(deadline: .now() + sequentialSendGap) {
                sendNext(parts, i + 1, targetContact)
            }
        }
    }
}
