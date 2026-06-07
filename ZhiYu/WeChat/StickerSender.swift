import AppKit
import ApplicationServices
import ZhiYuCore

/// 用微信自带"表情搜索"发原生表情：
/// AXPress「表情」按钮开面板 → 坐标点底部第一个图标(🔍)进搜索 → 写关键词+AXConfirm → 轮询结果 → AXPress 第一个。
/// 任一步超时则 beep 并中止（不会乱发）。除 🔍 一处坐标点击外全用 AX 动作；坐标运行时从 AX 读取。
@MainActor
enum StickerSender {
    // MARK: - 启发式几何/时序常量（值与抽取前完全一致）

    /// 底部工具栏(🔍/😀/❤️/表情包 那条)的最大高度（点）：用于从诸多 AXScrollArea 中筛出矮条工具栏。
    private static let toolbarMaxHeight: CGFloat = 80
    /// 工具栏「横向铺满」判定占 popover 宽度的最小比例：宽度 ≥ popover 宽 × 此值，排除窄 Tab 条。
    private static let toolbarWidthFraction: CGFloat = 0.5
    /// 搜索结果格的最小宽/高（点）：小于此尺寸的 AXStaticText 不视为表情结果（排除 Tab/搜索中态）。
    private static let resultCellMinSize: CGFloat = 60

    /// 等表情面板(popover)出现的轮询超时（秒）。
    private static let popoverPollTimeout: TimeInterval = 2.0
    /// 等进入搜索框的轮询超时（秒）。
    private static let searchFieldPollTimeout: TimeInterval = 1.6
    /// 等搜索结果首次出现的轮询超时（秒）。
    private static let resultPollTimeout: TimeInterval = 3.5
    /// 结果稳定后重定位首个结果格的轮询超时（秒）。
    private static let resultRelocatePollTimeout: TimeInterval = 0.6

    /// 点 🔍 前等面板布局稳定再读其 frame 的延时（纳秒，80ms）。
    private static let layoutSettleNanos: UInt64 = 80_000_000
    /// 让结果网格排序稳定、再重定位首格的延时（纳秒，250ms）。
    private static let resultGridSettleNanos: UInt64 = 250_000_000
    /// poll() 的轮询步进（纳秒，60ms，更跟手）。
    private static let pollStepNanos: UInt64 = 60_000_000

    static func send(keyword: String, targetContact: String? = nil) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        Task { _ = await run(keyword: kw, targetContact: targetContact) }
    }

    @discardableResult
    static func run(keyword: String, targetContact: String? = nil) async -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { fail("无辅助功能权限或未找到微信"); return false }
        app.activate(options: [])
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)

        // 1) 打开表情面板：AXPress 主窗口右侧「表情」按钮。
        guard let window = WeChatAXProbe.focusedOrMainWindow(of: appEl) else { fail("拿不到微信窗口"); return false }
        let panelRoot = WeChatAXProbe.rightPanelRoot(window: window)
        guard let emojiBtn = findButton(in: panelRoot, title: WeChatMarkers.emojiButtonTitle) else { fail("未找到「表情」按钮"); return false }
        AXUIElementPerformAction(emojiBtn, AXAction.press as CFString)

        // 2) 等 popover（app 顶层浅查，避免 DFS 扎进左侧巨表导致误返回 nil/变慢）。
        guard let popover = await poll(timeout: popoverPollTimeout, { findPopoverShallow(appEl) ?? findRole(AXRole.popover, in: appEl) })
        else { fail("表情面板(popover)未出现"); return false }

        // 3) 进搜索：🔍 无 AX 动作（只是无标签 AXImage），只能坐标点。
        //    搜索框已在(面板记住搜索态)则跳过；否则等面板布局稳定后直接坐标点 🔍——不再做无谓的 AXPress + 轮询等待。
        if searchField(in: popover) == nil {
            try? await Task.sleep(nanoseconds: layoutSettleNanos)  // 等面板布局稳定再读 🔍 frame
            if let first = bottomToolbarFirstItem(in: popover), let f = WeChatAXProbe.frame(of: first) {
                clickAt(CGPoint(x: f.midX, y: f.midY))
            } else {
                NSLog("[StickerSender] 警告：未定位到底部工具栏🔍项")
            }
        }
        guard let field = await poll(timeout: searchFieldPollTimeout, { searchField(in: popover) }) else { fail("未进入表情搜索框"); return false }

        // 4) 写关键词 + 回车。
        AXUIElementSetAttributeValue(field, AXAttr.value as CFString, keyword as CFString)
        AXUIElementPerformAction(field, AXAction.confirm as CFString)

        // 5) 轮询结果（有 Press 且 ≥60×60，排除 Tab/搜索中），稳定后重定位取最靠左上的第一个，AXPress。
        guard await poll(timeout: resultPollTimeout, { firstResultCell(in: popover) }) != nil
        else { fail("未搜到「\(keyword)」的表情结果"); return false }
        try? await Task.sleep(nanoseconds: resultGridSettleNanos)  // 让结果网格排序稳定
        // 不复用首次句柄（结果可能整体重建而失效），稳定后重新定位。
        guard let target = await poll(timeout: resultRelocatePollTimeout, { firstResultCell(in: popover) }) else { fail("结果重定位失败"); return false }
        // 真正发出表情前再校验会话身份：等待期间用户可能切会话，切了就中止不发。默认放行（isCurrentContact 内部处理）。
        guard WeChatAXProbe.isCurrentContact(targetContact) else { fail("会话已切换，已取消发表情"); return false }
        AXUIElementPerformAction(target, AXAction.press as CFString)
        NSLog("[StickerSender] 已 AXPress 第一个结果，关键词=%@", keyword)
        return true
    }

    // MARK: - 定位

    private static func searchField(in popover: AXUIElement) -> AXUIElement? {
        findFirst(in: popover) { el in
            (WeChatAXProbe.copyString(el, AXAttr.placeholderValue) == WeChatMarkers.stickerSearchPlaceholder)
                && isSettable(el, AXAttr.value)
        }
    }

    /// 底部工具栏(🔍/😀/❤️/表情包 那条)的第一个图标项(= 🔍)。
    /// 特征：矮(height≤80) 且 横向铺满(宽度≥popover 宽度一半，排除窄 Tab 条)；取**最靠底**的那条。
    private static func bottomToolbarFirstItem(in popover: AXUIElement) -> AXUIElement? {
        let popW = WeChatAXProbe.frame(of: popover)?.width ?? 0
        var scrolls: [AXUIElement] = []
        collectRole(AXRole.scrollArea, in: popover, into: &scrolls)
        let toolbar = scrolls
            .filter {
                guard let f = WeChatAXProbe.frame(of: $0) else { return false }
                return f.height <= toolbarMaxHeight && (popW <= 0 || f.width >= popW * toolbarWidthFraction)
            }
            .max(by: { (WeChatAXProbe.frame(of: $0)?.minY ?? -1) < (WeChatAXProbe.frame(of: $1)?.minY ?? -1) })
        guard let toolbar else { return nil }
        var groups: [AXUIElement] = []
        collectRole(AXRole.group, in: toolbar, into: &groups)
        // 排序前把 (element, frame) 物化为快照：sort 闭包不再二次读 AX、不再 force-unwrap。
        return groups
            .compactMap { el in WeChatAXProbe.frame(of: el).map { (el, $0) } }
            .min(by: { ($0.1.minX, $0.1.minY) < ($1.1.minX, $1.1.minY) })?
            .0
    }

    private static func firstResultCell(in popover: AXUIElement) -> AXUIElement? {
        var cells: [AXUIElement] = []
        collectMatching(in: popover, into: &cells) { el in
            guard WeChatAXProbe.role(el) == AXRole.staticText,
                  let f = WeChatAXProbe.frame(of: el), f.width >= resultCellMinSize, f.height >= resultCellMinSize else { return false }
            return WeChatAXProbe.actions(el).contains(AXAction.press)
        }
        // 排序前把 (element, frame) 物化为快照：sort 闭包不再二次读 AX、不再 force-unwrap。
        return cells
            .compactMap { el in WeChatAXProbe.frame(of: el).map { (el, $0) } }
            .min(by: { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) })?
            .0
    }

    // MARK: - AX 遍历/动作工具

    private static func findButton(in root: AXUIElement, title: String) -> AXUIElement? {
        findFirst(in: root) { WeChatAXProbe.role($0) == AXRole.button && WeChatAXProbe.copyString($0, AXAttr.title) == title }
    }
    private static func findRole(_ role: String, in root: AXUIElement) -> AXUIElement? {
        findFirst(in: root) { WeChatAXProbe.role($0) == role }
    }
    /// 只在 app 顶层浅查 AXPopover（深度≤3），避免 DFS 深入左侧聊天巨表（项目已知性能痛点）。
    /// popover 通常是 app 的顶层子节点；这层只触及个位数节点，触不到表格行。
    private static func findPopoverShallow(_ appEl: AXUIElement) -> AXUIElement? {
        func scan(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
            if WeChatAXProbe.role(el) == AXRole.popover { return el }
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
            if result != nil || n > AXWalkLimit.maxNodes || d > AXWalkLimit.maxDepth { return }
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
            if n > AXWalkLimit.maxNodes || d > AXWalkLimit.maxDepth { return }
            n += 1
            if match(el) { out.append(el) }
            for c in WeChatAXProbe.children(el) { walk(c, d + 1) }
        }
        walk(root, 0)
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
            try? await Task.sleep(nanoseconds: pollStepNanos)
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
