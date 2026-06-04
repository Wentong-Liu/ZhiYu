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

    /// 触发单条气泡的「转文字」。成功点到「转文字」返回 true，否则 false（自己发的/不支持/没等到）。
    /// 关键：在 0.6s 窗口内**持续等待**「转文字」项出现；不因"出现了一个没有转文字项的菜单"就取消跳过
    /// （那可能是上一条残留菜单或菜单还没填充好）。只有整个窗口都没等到才放弃。
    private static func triggerTranscribe(_ bubble: AXUIElement, panel: AXUIElement, appEl: AXUIElement) async -> Bool {
        guard actions(bubble).contains("AXShowMenu") else { return false }
        // 弹菜单前先确保无残留菜单，避免本条 AXShowMenu 命中旧菜单。
        await waitMenuDismissed(panel: panel)
        // 临时埋点：单独测 AXShowMenu 调用本身耗时（怀疑此调用阻塞 ~1.5s）。
        let tA = ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(bubble, 0.05)  // 该 AX 调用最多等 50ms 就返回；菜单已弹出，无需傻等 ~1.5s
        AXUIElementPerformAction(bubble, "AXShowMenu" as CFString)
        let showMs = (ProcessInfo.processInfo.systemUptime - tA) * 1000

        // 0.6s 窗口内持续轮询（步进 20ms），等「转文字」项出现。热路径只查右面板（瞬时）。
        var target: AXUIElement?
        var iters = 0  // 临时埋点：轮询迭代次数
        let tLoop = ProcessInfo.processInfo.systemUptime  // 临时埋点：轮询起点
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.6 {
            iters += 1
            if Task.isCancelled { return false }  // ESC 已取消：放弃本条触发
            if let menu = dfsMenu(panel), let it = transcribeItem(in: menu) {
                target = it
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let loopMs = (ProcessInfo.processInfo.systemUptime - tLoop) * 1000  // 临时埋点：轮询总耗时
        // 临时埋点：右面板轮询结束时的节点数 / 是否在右面板命中
        let panelNodes = Self.lastDfsNodes
        let foundInPanel = (target != nil)

        // 一次性全树兜底：右面板没找到时，才做一次慢但稳的全树深遍历（每条最多一次）。
        if target == nil, let menu = dfsMenu(appEl), let it = transcribeItem(in: menu) {
            target = it
        }
        // 临时埋点：若走了全树兜底（右面板未命中但兜底命中），记 fallback 那次 dfsMenu(appEl) 的节点数；否则 -1
        let fallbackNodes = (!foundInPanel && target != nil) ? Self.lastDfsNodes : -1
        _ = fallbackNodes  // 暂留兜底节点数变量（细化日志已不打印），避免误删兜底逻辑

        guard let target else {
            // 临时埋点：none 路径也记一行，便于核对没找到的占比与耗时
            NSLog("[VT] 单条: AXShowMenu=%.0fms 轮询=%.0fms(%d次) via=none panelNodes=%d 关菜单=-1ms",
                  showMs, loopMs, iters, panelNodes)
            // 整个窗口都没等到「转文字」：兜底关掉此刻任何遗留菜单，再放弃这条。
            if let stray = dfsMenu(panel) {
                AXUIElementPerformAction(stray, "AXCancel" as CFString)
                await waitMenuDismissed(panel: panel)
            }
            return false
        }

        AXUIElementPerformAction(target, "AXPress" as CFString)  // 选中即关菜单并开始转写（服务器异步转）
        // AXPress 后也等菜单收起（短超时），避免下一条 AXShowMenu 命中本条还没收起的旧菜单。
        let tPress = ProcessInfo.processInfo.systemUptime  // 临时埋点：AXPress 后等关菜单起点
        await waitMenuDismissed(panel: panel)
        let dismissMs = (ProcessInfo.processInfo.systemUptime - tPress) * 1000  // 临时埋点：关菜单耗时
        NSLog("[VT] 单条: AXShowMenu=%.0fms 轮询=%.0fms(%d次) via=%@ panelNodes=%d 关菜单=%.0fms",
              showMs, loopMs, iters, foundInPanel ? "panel" : (target != nil ? "FALLBACK" : "none"), panelNodes, dismissMs)
        return true
    }

    /// 气泡是否已完成转写：bestText 含「已转文字」，或不再是「发送了一个语音」占位。
    private static func isTranscribed(_ bubble: AXUIElement) -> Bool {
        guard let t = WeChatAXProbe.bestText(bubble) else { return true }
        return t.contains("已转文字") || !t.contains("发送了一个语音")
    }

    /// 轮询直到右面板内已无 AXMenu（菜单收起）或 ~0.35s 超时；步进 20ms。
    /// 只查右面板（瞬时），不再做全树扫描；只等菜单关闭，不等转写结果，整体仍是「快速点过去」的策略。
    private static func waitMenuDismissed(panel: AXUIElement) async {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.35 {
            if Task.isCancelled { return }  // ESC 已取消：停止等待菜单收起
            if dfsMenu(panel) == nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
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
