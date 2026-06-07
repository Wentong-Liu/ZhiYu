import AppKit

/// 候选落地：仅填入，或填入并发送。复用 Phase 1 验证过的 InserterProbe。
@MainActor
enum Inserter {
    /// 发送前轮询输入框就绪的间隔（约 60ms 一次）。
    private static let readinessPollInterval: TimeInterval = 0.06
    /// 发送前轮询的总超时（超过仍不就绪则放弃回车，约 1.5s）。
    private static let readinessTimeout: TimeInterval = 1.5
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
            // 据 sendReturn 实际投递结果决定 completion：回车未真正发出（CGEvent 建失败）时返回 false，
            // 让逐条发送停止后续以免覆盖/乱序。正常成功路径 sendReturn 返回 true，行为不变。
            let posted = InserterProbe.sendReturn()
            completion(posted)
            return
        }
        guard DispatchTime.now() < deadline else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollInterval) {
            pollUntilReady(text, deadline: deadline, completion: completion)
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
