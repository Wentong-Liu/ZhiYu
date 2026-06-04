import AppKit
import ApplicationServices

/// 自动"语音转文字"：把右侧会话面板里**当前已加载、未转文字**的语音气泡全部触发转文字。
/// 机制（已探测确认）：对气泡 `AXShowMenu` 弹右键菜单 → 找标题=「转文字」的 enabled `AXMenuItem` → `AXPress`。
/// 自己发的/无「转文字」项的气泡自动跳过。转写是服务器异步返回，故全部触发后统一等一会儿再交给调用方重读。
@MainActor
enum VoiceTranscriber {
    /// 触发当前已加载的全部未转语音的转文字。返回成功触发的条数。
    @discardableResult
    static func transcribeLoaded() async -> Int {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return 0 }
        app.activate(options: [])
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { return 0 }
        let panel = WeChatAXProbe.rightPanelRoot(window: window)

        // 文档顺序是 上(旧)→下(新)；从下往上（最新的先转），快速点过去，不等单条转写结果（微信支持并发转写）。
        let voices = unconvertedVoices(in: panel).reversed()
        guard !voices.isEmpty else { return 0 }

        var done = 0
        for v in voices {
            if await convertOne(v, appEl: appEl) { done += 1 }
        }
        // 全部触发后统一等服务器转写回来，让随后的重读能读到文本。
        if done > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        NSLog("[VoiceTranscriber] 触发转文字 %d 条（共 %d 条未转）", done, Array(voices).count)
        return done
    }

    /// 当前是否有已加载的未转语音（便于调用方决定是否走转写流程）。
    static func hasUnconvertedLoaded() -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { return false }
        return !unconvertedVoices(in: WeChatAXProbe.rightPanelRoot(window: window)).isEmpty
    }

    // MARK: - 单条转写

    private static func convertOne(_ bubble: AXUIElement, appEl: AXUIElement) async -> Bool {
        guard actions(bubble).contains("AXShowMenu") else { return false }
        AXUIElementPerformAction(bubble, "AXShowMenu" as CFString)
        // 等菜单出现并拿到「转文字」项（最多 0.8s）。
        var target: AXUIElement?
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.8 {
            if let menu = findFirstRole("AXMenu", in: appEl) {
                if let it = transcribeItem(in: menu) { target = it; break }
                // 菜单已出但没有「转文字」（自己发的/不支持）→ 关掉，等它真正消失再跳过，
                // 避免遗留菜单被下一条 AXShowMenu 命中（findFirstRole 找的是全 app 第一个菜单）。
                AXUIElementPerformAction(menu, "AXCancel" as CFString)
                await waitMenuDismissed(appEl: appEl)
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let target else {
            // 0.8s 内菜单始终没出现：兜底关掉任何此刻遗留的游离菜单，再返回。
            if let stray = findFirstRole("AXMenu", in: appEl) {
                AXUIElementPerformAction(stray, "AXCancel" as CFString)
                await waitMenuDismissed(appEl: appEl)
            }
            return false
        }
        AXUIElementPerformAction(target, "AXPress" as CFString)  // 选中即关菜单并开始转写（服务器异步转，不等结果）
        // 只等「菜单关闭」（几十毫秒级），不等服务器转写返回；确认菜单消失再放行下一条，
        // 防止下一条 AXShowMenu 时命中上一条还没收起的旧菜单造成漏转/转错。
        await waitMenuDismissed(appEl: appEl)
        return true
    }

    /// 轮询直到全 app 内已无 AXMenu（菜单收起）或 ~0.5s 超时；小步轮询约 40ms/步。
    /// 我们只等菜单关闭，不等转写结果，整体仍是「快速点过去」的策略。
    private static func waitMenuDismissed(appEl: AXUIElement) async {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.5 {
            if findFirstRole("AXMenu", in: appEl) == nil { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
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

    private static func findFirstRole(_ role: String, in root: AXUIElement) -> AXUIElement? {
        var result: AXUIElement?
        var n = 0
        func walk(_ el: AXUIElement, _ d: Int) {
            if result != nil || n > 6000 || d > 45 { return }
            n += 1
            if WeChatAXProbe.role(el) == role { result = el; return }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1); if result != nil { return } }
        }
        walk(root, 0)
        return result
    }

    private static func actions(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(el, &arr) == .success, let a = arr as? [String] else { return [] }
        return a
    }
}
