import AppKit
import ApplicationServices

/// 用微信自带"表情搜索"发原生表情：
/// AXPress「表情」按钮开面板 → 坐标点底部第一个图标(🔍)进搜索 → 写关键词+AXConfirm → 轮询结果 → AXPress 第一个。
/// 任一步超时则 beep 并中止（不会乱发）。除 🔍 一处坐标点击外全用 AX 动作；坐标运行时从 AX 读取。
@MainActor
enum StickerSender {
    static func send(keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        Task { _ = await run(keyword: kw) }
    }

    @discardableResult
    static func run(keyword: String) async -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { fail("无辅助功能权限或未找到微信"); return false }
        app.activate(options: [])
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)

        // 1) 打开表情面板：AXPress 主窗口右侧「表情」按钮。
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { fail("拿不到微信窗口"); return false }
        let panelRoot = WeChatAXProbe.rightPanelRoot(window: window)
        guard let emojiBtn = findButton(in: panelRoot, title: "表情") else { fail("未找到「表情」按钮"); return false }
        AXUIElementPerformAction(emojiBtn, "AXPress" as CFString)

        let t0 = ProcessInfo.processInfo.systemUptime

        // 2) 等 popover（app 顶层浅查，避免 DFS 扎进左侧巨表导致误返回 nil/变慢）。
        guard let popover = await poll(timeout: 2.0, { findPopoverShallow(appEl) ?? findRole("AXPopover", in: appEl) })
        else { fail("表情面板(popover)未出现"); return false }
        NSLog("[StickerSender] popover 用时 %.0fms", (ProcessInfo.processInfo.systemUptime - t0) * 1000)

        // 3) 进搜索：🔍 无 AX 动作（只是无标签 AXImage），只能坐标点。
        //    搜索框已在(面板记住搜索态)则跳过；否则等面板布局稳定后直接坐标点 🔍——不再做无谓的 AXPress + 轮询等待。
        if searchField(in: popover) == nil {
            try? await Task.sleep(nanoseconds: 80_000_000)  // 等面板布局稳定再读 🔍 frame
            if let first = bottomToolbarFirstItem(in: popover), let f = WeChatAXProbe.frame(of: first) {
                clickAt(CGPoint(x: f.midX, y: f.midY))
            } else {
                NSLog("[StickerSender] 警告：未定位到底部工具栏🔍项")
            }
        }
        guard let field = await poll(timeout: 1.6, { searchField(in: popover) }) else { fail("未进入表情搜索框"); return false }
        NSLog("[StickerSender] 进入搜索 用时 %.0fms", (ProcessInfo.processInfo.systemUptime - t0) * 1000)

        // 4) 写关键词 + 回车。
        AXUIElementSetAttributeValue(field, "AXValue" as CFString, keyword as CFString)
        AXUIElementPerformAction(field, "AXConfirm" as CFString)

        // 5) 轮询结果（有 Press 且 ≥60×60，排除 Tab/搜索中），稳定后重定位取最靠左上的第一个，AXPress。
        guard await poll(timeout: 3.5, { firstResultCell(in: popover) }) != nil
        else { fail("未搜到「\(keyword)」的表情结果"); return false }
        try? await Task.sleep(nanoseconds: 250_000_000)  // 让结果网格排序稳定
        // 不复用首次句柄（结果可能整体重建而失效），稳定后重新定位。
        guard let target = await poll(timeout: 0.6, { firstResultCell(in: popover) }) else { fail("结果重定位失败"); return false }
        AXUIElementPerformAction(target, "AXPress" as CFString)
        NSLog("[StickerSender] 已 AXPress 第一个结果，关键词=%@", keyword)
        return true
    }

    // MARK: - 定位

    private static func searchField(in popover: AXUIElement) -> AXUIElement? {
        findFirst(in: popover) { el in
            (WeChatAXProbe.copyString(el, "AXPlaceholderValue") == "搜索表情")
                && isSettable(el, "AXValue")
        }
    }

    /// 底部工具栏(🔍/😀/❤️/表情包 那条)的第一个图标项(= 🔍)。
    /// 特征：矮(height≤80) 且 横向铺满(宽度≥popover 宽度一半，排除窄 Tab 条)；取**最靠底**的那条。
    private static func bottomToolbarFirstItem(in popover: AXUIElement) -> AXUIElement? {
        let popW = WeChatAXProbe.frame(of: popover)?.width ?? 0
        var scrolls: [AXUIElement] = []
        collectRole("AXScrollArea", in: popover, into: &scrolls)
        let toolbar = scrolls
            .filter {
                guard let f = WeChatAXProbe.frame(of: $0) else { return false }
                return f.height <= 80 && (popW <= 0 || f.width >= popW * 0.5)
            }
            .max(by: { (WeChatAXProbe.frame(of: $0)?.minY ?? -1) < (WeChatAXProbe.frame(of: $1)?.minY ?? -1) })
        guard let toolbar else { return nil }
        var groups: [AXUIElement] = []
        collectRole("AXGroup", in: toolbar, into: &groups)
        return groups
            .filter { WeChatAXProbe.frame(of: $0) != nil }
            .min(by: { lhs, rhs in
                let a = WeChatAXProbe.frame(of: lhs)!, b = WeChatAXProbe.frame(of: rhs)!
                return (a.minX, a.minY) < (b.minX, b.minY)
            })
    }

    private static func firstResultCell(in popover: AXUIElement) -> AXUIElement? {
        var cells: [AXUIElement] = []
        collectMatching(in: popover, into: &cells) { el in
            guard WeChatAXProbe.role(el) == "AXStaticText",
                  let f = WeChatAXProbe.frame(of: el), f.width >= 60, f.height >= 60 else { return false }
            return actions(el).contains("AXPress")
        }
        return cells.min(by: { lhs, rhs in
            let a = WeChatAXProbe.frame(of: lhs)!, b = WeChatAXProbe.frame(of: rhs)!
            return (a.minY, a.minX) < (b.minY, b.minX)
        })
    }

    // MARK: - AX 遍历/动作工具

    private static func findButton(in root: AXUIElement, title: String) -> AXUIElement? {
        findFirst(in: root) { WeChatAXProbe.role($0) == "AXButton" && WeChatAXProbe.copyString($0, "AXTitle") == title }
    }
    private static func findRole(_ role: String, in root: AXUIElement) -> AXUIElement? {
        findFirst(in: root) { WeChatAXProbe.role($0) == role }
    }
    /// 只在 app 顶层浅查 AXPopover（深度≤3），避免 DFS 深入左侧聊天巨表（项目已知性能痛点）。
    /// popover 通常是 app 的顶层子节点；这层只触及个位数节点，触不到表格行。
    private static func findPopoverShallow(_ appEl: AXUIElement) -> AXUIElement? {
        func scan(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
            if WeChatAXProbe.role(el) == "AXPopover" { return el }
            guard d < 3 else { return nil }
            for c in WeChatAXProbe.children(el) { if let hit = scan(c, d + 1) { return hit } }
            return nil
        }
        for c in WeChatAXProbe.children(appEl) { if let hit = scan(c, 1) { return hit } }
        return nil
    }
    private static func findFirst(in root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var result: AXUIElement?; var n = 0
        func walk(_ el: AXUIElement, _ d: Int) {
            if result != nil || n > 6000 || d > 45 { return }
            n += 1
            if match(el) { result = el; return }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1); if result != nil { return } }
        }
        walk(root, 0); return result
    }
    private static func collectRole(_ role: String, in root: AXUIElement, into out: inout [AXUIElement]) {
        collectMatching(in: root, into: &out) { WeChatAXProbe.role($0) == role }
    }
    private static func collectMatching(in root: AXUIElement, into out: inout [AXUIElement], _ match: (AXUIElement) -> Bool) {
        var n = 0
        func walk(_ el: AXUIElement, _ d: Int) {
            if n > 8000 || d > 45 { return }
            n += 1
            if match(el) { out.append(el) }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1) }
        }
        walk(root, 0)
    }
    private static func actions(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(el, &arr) == .success, let a = arr as? [String] else { return [] }
        return a
    }
    private static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success && b.boolValue
    }

    /// 反复调用 probe 直到返回非 nil 或超时（步进 60ms，更跟手）。
    private static func poll<T>(timeout: TimeInterval, _ probe: () -> T?) async -> T? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if let v = probe() { return v }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return probe()
    }

    /// 在全局坐标(AX 左上原点，与 CGEvent 全局坐标一致)点击一次。会移动光标。
    private static func clickAt(_ p: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// 失败：记一条带阶段的日志（便于联调定位是哪一步挂了）+ 一声 beep。不会乱发。
    private static func fail(_ stage: String) {
        NSLog("[StickerSender] 失败：%@", stage)
        NSSound.beep()
    }
}
