import AppKit
import ApplicationServices

/// 自动"语音转文字"：把右侧会话面板里**最近、未转文字**的语音气泡触发转文字并等到转写落地。
/// 机制（已探测确认）：对气泡 `AXShowMenu` 弹右键菜单 → 找标题=「转文字」的 enabled `AXMenuItem` → `AXPress`。
/// 自己发的/无「转文字」项的气泡自动跳过。转写是服务器异步返回，触发后轮询每个气泡的文本直至落地再返回。
@MainActor
enum VoiceTranscriber {
    /// 并发护栏：避免两处（如 prewarm + present）同时驱动右键菜单互相打架。
    private static var isRunning = false

    /// 临时性能埋点：记录最近一次 dfsMenu(_:) walk 访问的 AX 节点数，供调用方读取（定位转文字 2s 延迟）。
    private static var lastDfsNodes = 0

    /// 触发"最近最多 `max` 条"未转语音的转文字，并**等到这些气泡都转写落地或 `timeout` 超时再返回**。
    /// - 取未转语音（新→旧），只取最前 `max` 条（我的 + 对方的合计）。
    /// - 逐条快速触发；触发完毕后轮询气泡文本，确认转写完成（出现「已转文字」或不再是「发送了一个语音」）。
    static func transcribeRecentAndWait(max: Int = 5, timeout: TimeInterval = 8) async {
        // 并发护栏：若已有一处在跑，等它结束（最多 timeout）再 return，不重复驱动菜单。
        if isRunning {
            let start = ProcessInfo.processInfo.systemUptime
            while isRunning, ProcessInfo.processInfo.systemUptime - start < timeout {
                if Task.isCancelled { return }  // ESC 已取消：不再等待
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        isRunning = true
        defer { isRunning = false }

        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return }
        if Task.isCancelled { return }  // ESC 已取消：不要再 activate 把微信拉前台
        app.activate(options: [])
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { return }
        let panel = WeChatAXProbe.rightPanelRoot(window: window)

        // 文档顺序是 上(旧)→下(新)；reversed() 得到 新→旧，prefix(max) 取最近最多 max 条。
        let targets = Array(unconvertedVoices(in: panel).reversed().prefix(max))
        guard !targets.isEmpty else { return }
        NSLog("[VT] 待转语音 %d 条(上限5)", targets.count)  // 临时埋点

        // 逐条快速触发，收集"成功点了转文字"的气泡，稍后轮询它们是否转写落地。
        var pressed: [AXUIElement] = []
        let tFireStart = ProcessInfo.processInfo.systemUptime  // 临时埋点：触发循环起点
        for bubble in targets {
            if Task.isCancelled { break }  // ESC 已取消：停止逐条触发，不再 AXShowMenu
            if await triggerTranscribe(bubble, panel: panel, appEl: appEl) { pressed.append(bubble) }
        }
        // 临时埋点：触发循环耗时（N=成功触发, M=目标条数）
        NSLog("[VT] 共触发 %d/%d 条 用时 %.0fms",
              pressed.count, targets.count, (ProcessInfo.processInfo.systemUptime - tFireStart) * 1000)
        guard !pressed.isEmpty else { return }

        // 转完再返回：轮询直到 pressed 里每个气泡都已转写或 timeout 到（步进 ~300ms）。
        let tWaitStart = ProcessInfo.processInfo.systemUptime  // 临时埋点：等转写落地起点
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { return }  // ESC 已取消：停止等待转写落地
            if pressed.allSatisfy(isTranscribed) { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        NSLog("[VT] 等转写落地 %.0fms", (ProcessInfo.processInfo.systemUptime - tWaitStart) * 1000)  // 临时埋点
        NSLog("[VoiceTranscriber] 触发转文字 %d/%d 条，等待转写落地完成", pressed.count, targets.count)
    }

    /// 当前是否有已加载的未转语音（便于调用方决定是否走转写流程）。
    static func hasUnconvertedLoaded() -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { return false }
        return !unconvertedVoices(in: WeChatAXProbe.rightPanelRoot(window: window)).isEmpty
    }

    // MARK: - 单条触发

    private static func triggerTranscribe(_ bubble: AXUIElement, panel: AXUIElement, appEl: AXUIElement) async -> Bool {
        guard actions(bubble).contains("AXShowMenu") else { return false }
        var target: AXUIElement?
        var foundMenu: AXUIElement?
        var attempts = 0
        let tStart = ProcessInfo.processInfo.systemUptime
        let overallDeadline = tStart + 1.6
        while ProcessInfo.processInfo.systemUptime < overallDeadline, target == nil {
            if Task.isCancelled { return false }
            attempts += 1
            AXUIElementSetMessagingTimeout(bubble, 0.05)
            let tShow = ProcessInfo.processInfo.systemUptime
            AXUIElementPerformAction(bubble, "AXShowMenu" as CFString)
            let showMs = (ProcessInfo.processInfo.systemUptime - tShow) * 1000
            // 动作刚返回，先廉价查一下菜单是否已出现（兼顾"接受且极快渲染"的情况，避免误重试）。
            if let menu = dfsMenu(panel), let it = transcribeItem(in: menu) { target = it; foundMenu = menu; break }
            if showMs < 30 {
                // ~1ms 立即返回 = 被微信短暂拒绝、菜单没弹 → 稍等直接重试 AXShowMenu，不空轮询。
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            // 已接受(~50ms 超时返回)但菜单尚未进 AX 树 → 短轮询等它出现。
            let pollEnd = ProcessInfo.processInfo.systemUptime + 0.3
            while ProcessInfo.processInfo.systemUptime < pollEnd {
                if Task.isCancelled { return false }
                if let menu = dfsMenu(panel), let it = transcribeItem(in: menu) { target = it; foundMenu = menu; break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if target == nil { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        if target == nil, let menu = dfsMenu(appEl), let it = transcribeItem(in: menu) { target = it; foundMenu = menu }
        let findMs = (ProcessInfo.processInfo.systemUptime - tStart) * 1000  // 临时埋点
        guard let target else {
            NSLog("[VT] 单条: 找菜单=%.0fms 尝试=%d次 via=none", findMs, attempts)
            if let stray = dfsMenu(panel) {
                AXUIElementPerformAction(stray, "AXCancel" as CFString)
                await waitMenuClosed(stray)
            }
            return false
        }
        AXUIElementPerformAction(target, "AXPress" as CFString)
        let tPress = ProcessInfo.processInfo.systemUptime  // 临时埋点
        if let m = foundMenu { await waitMenuClosed(m) }
        let dismissMs = (ProcessInfo.processInfo.systemUptime - tPress) * 1000  // 临时埋点
        NSLog("[VT] 单条: 找菜单=%.0fms 尝试=%d次 via=panel 关菜单=%.0fms", findMs, attempts, dismissMs)
        return true
    }

    /// 气泡是否已完成转写：bestText 含「已转文字」，或不再是「发送了一个语音」占位。
    private static func isTranscribed(_ bubble: AXUIElement) -> Bool {
        guard let t = WeChatAXProbe.bestText(bubble) else { return true }
        return t.contains("已转文字") || !t.contains("发送了一个语音")
    }

    /// 廉价地等"指定菜单元素"关闭：只查这一个元素是否还是 AXMenu（单元素、~毫秒级），
    /// 并给它设 50ms 消息超时，避免对已失效元素的查询阻塞。最多等 0.3s。
    private static func waitMenuClosed(_ menu: AXUIElement) async {
        AXUIElementSetMessagingTimeout(menu, 0.05)
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.3 {
            if Task.isCancelled { return }
            if WeChatAXProbe.role(menu) != "AXMenu" { return }  // 元素已失效/不再是菜单 = 已关
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// 菜单里标题 trim 后等于「转文字」且 enabled 的菜单项。
    private static func transcribeItem(in menu: AXUIElement) -> AXUIElement? {
        for it in WeChatAXProbe.children(menu) where WeChatAXProbe.role(it) == "AXMenuItem" {
            let title = (WeChatAXProbe.copyString(it, "AXTitle") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = WeChatAXProbe.copyBool(it, "AXEnabled") ?? true
            if title == "转文字", enabled { return it }
        }
        return nil
    }

    // MARK: - 查找

    /// 未转文字的语音气泡：bestText 含「发送了一个语音」但不含「已转文字」。
    static func unconvertedVoices(in root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var n = 0
        func walk(_ el: AXUIElement, _ d: Int) {
            if n > 9000 || d > 55 { return }
            n += 1
            if let t = WeChatAXProbe.bestText(el), t.contains("发送了一个语音"), !t.contains("已转文字") {
                out.append(el)
            }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1) }
        }
        walk(root, 0)
        return out
    }

    /// 在给定子树里深遍历找第一个 AXMenu。热路径传右面板（瞬时）；全树兜底传 appEl（慢但稳，每条最多一次）。
    private static func dfsMenu(_ root: AXUIElement) -> AXUIElement? {
        var result: AXUIElement?
        var n = 0
        func walk(_ el: AXUIElement, _ d: Int) {
            if result != nil || n > 8000 || d > 60 { return }
            n += 1
            if WeChatAXProbe.role(el) == "AXMenu" { result = el; return }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1); if result != nil { return } }
        }
        walk(root, 0)
        lastDfsNodes = n  // 临时埋点：记录本次 walk 访问的节点数
        return result
    }

    private static func actions(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(el, &arr) == .success, let a = arr as? [String] else { return [] }
        return a
    }
}
