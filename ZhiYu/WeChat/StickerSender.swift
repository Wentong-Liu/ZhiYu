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
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { fail(); return false }
        app.activate(options: [])
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)

        // 1) 打开表情面板：AXPress 主窗口右侧「表情」按钮。
        guard let window = WeChatAXProbe.copyElement(appEl, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appEl, "AXMainWindow") else { fail(); return false }
        let panelRoot = WeChatAXProbe.rightPanelRoot(window: window)
        guard let emojiBtn = findButton(in: panelRoot, title: "表情") else { fail(); return false }
        AXUIElementPerformAction(emojiBtn, "AXPress" as CFString)

        // 2) 等 popover。
        guard let popover = await poll(timeout: 1.6, { findRole("AXPopover", in: appEl) }) else { fail(); return false }

        // 3) 进搜索：优先 AXPress 底部工具栏第一个 item；不行则坐标点击其中心。
        if (await poll(timeout: 0.6, { searchField(in: popover) })) == nil {
            if let first = bottomToolbarFirstItem(in: popover) {
                AXUIElementPerformAction(first, "AXPress" as CFString)
                if (await poll(timeout: 0.5, { searchField(in: popover) })) == nil,
                   let f = WeChatAXProbe.frame(of: first) {
                    clickAt(CGPoint(x: f.midX, y: f.midY))
                }
            }
        }
        guard let field = await poll(timeout: 1.6, { searchField(in: popover) }) else { fail(); return false }

        // 4) 写关键词 + 回车。
        AXUIElementSetAttributeValue(field, "AXValue" as CFString, keyword as CFString)
        AXUIElementPerformAction(field, "AXConfirm" as CFString)

        // 5) 轮询结果（有 Press 且 ≥60×60，排除 Tab/搜索中），取最靠左上的第一个，AXPress。
        guard let cell = await poll(timeout: 3.5, { firstResultCell(in: popover) }) else { fail(); return false }
        try? await Task.sleep(nanoseconds: 200_000_000)  // 让排序稳定一下
        let target = firstResultCell(in: popover) ?? cell
        AXUIElementPerformAction(target, "AXPress" as CFString)
        return true
    }

    // MARK: - 定位

    private static func searchField(in popover: AXUIElement) -> AXUIElement? {
        findFirst(in: popover) { el in
            (WeChatAXProbe.copyString(el, "AXPlaceholderValue") == "搜索表情")
                && isSettable(el, "AXValue")
        }
    }

    /// 底部工具栏（height≈48 的 AXScrollArea）里的第一个有 frame 的 AXGroup（= 🔍）。
    private static func bottomToolbarFirstItem(in popover: AXUIElement) -> AXUIElement? {
        var scrolls: [AXUIElement] = []
        collectRole("AXScrollArea", in: popover, into: &scrolls)
        let toolbar = scrolls
            .filter { (WeChatAXProbe.frame(of: $0)?.height ?? 999) <= 80 }
            .min(by: { (WeChatAXProbe.frame(of: $0)?.height ?? 999) < (WeChatAXProbe.frame(of: $1)?.height ?? 999) })
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

    /// 反复调用 probe 直到返回非 nil 或超时（步进 120ms）。
    private static func poll<T>(timeout: TimeInterval, _ probe: () -> T?) async -> T? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if let v = probe() { return v }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return probe()
    }

    /// 在全局坐标(AX 左上原点，与 CGEvent 全局坐标一致)点击一次。会移动光标。
    private static func clickAt(_ p: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func fail() { NSSound.beep() }
}
