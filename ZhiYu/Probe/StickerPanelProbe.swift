import AppKit
import ApplicationServices

/// 【临时诊断】导出微信「表情面板」（点笑脸 → 🔍搜索后）的 AX 结构，
/// 判断能否程序化驱动「搜索表情 → 点结果 → 发送」这条路。
///
/// 用法：在微信里点笑脸打开表情面板 → 点左下角 🔍 → 输入关键词（如「报警」）等结果出来
///       → 在微信前台**双击左 Command** → 结果写入 .local-notes/sticker-panel-ax.txt（同时复制到剪贴板）。
///
/// PII 安全：优先只整树 dump「浮层 Popover / 非标准窗口」（表情面板就是个 popover）；
/// 万一面板挂在主窗口之下，则退化为「定向收集」——只摘搜索框/标签/少量结果格子，绝不整窗 dump 聊天内容。
/// 仅诊断用，验证完连同 StickerProbeHotkey 一起删除。
@MainActor
enum StickerPanelProbe {
    /// 直接写到仓库的 gitignored 笔记目录（App 运行时 CWD 不在仓库，故用绝对路径）。
    private static let outPath = "/Users/liuwentong/Project/me/ZhiYu/.local-notes/sticker-panel-ax.txt"
    /// 表情面板的标志性文案：搜索框占位符 / 顶部两个 Tab。
    private static let markers = ["搜索表情", "全部表情", "合成表情"]

    static func dump() {
        var out = "# 微信表情面板 AX dump（诊断）\n"
        guard AXIsProcessTrusted() else { finish(out + "✗ 未授予辅助功能权限\n"); return }
        guard let app = WeChatAXProbe.findWeChatApp() else { finish(out + "✗ 未找到运行中的微信\n"); return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appEl)

        // 窗口拓扑（每个窗口一行：role/subrole/frame/title），并标出哪些含表情面板标志。
        let windows = axElements(appEl, "AXWindows")
        out += "应用窗口数: \(windows.count)\n"
        for (i, w) in windows.enumerated() {
            let mark = subtreeContainsMarker(w) ? "  ←含表情面板标志" : ""
            out += "  窗口[\(i)] \(nodeLine(w))\(mark)\n"
        }

        // 找浮层：① app/窗口子树里的 AXPopover（含标志优先）；② 含标志且 subrole≠标准窗口的浮层窗口。
        let popover = findRole("AXPopover", under: [appEl] + windows, requireMarker: true)
            ?? findRole("AXPopover", under: [appEl] + windows, requireMarker: false)
        let markedWindows = windows.filter { subtreeContainsMarker($0) }
        let floatingWindow = markedWindows.first {
            (WeChatAXProbe.copyString($0, "AXSubrole") ?? "") != "AXStandardWindow"
        }

        if let panel = popover {
            out += "\n## 命中 AXPopover，整树 dump（PII 安全：只是表情面板）：\n"
            out += dumpTree(panel)
        } else if let panel = floatingWindow {
            out += "\n## 命中浮层窗口（非标准窗口），整树 dump：\n"
            out += dumpTree(panel)
        } else if let host = markedWindows.first {
            out += "\n## 面板疑似挂在主窗口之下 → 仅定向收集（PII 安全，不整窗 dump）：\n"
            out += targetedCollect(in: host)
        } else {
            out += "\n✗ 未发现含『搜索表情/全部表情/合成表情』的窗口或浮层。\n"
            out += "  请确认：已点笑脸打开表情面板（默认视图即可），再双击左⌘。\n"
        }

        // 额外：定位主窗口右侧面板底部工具栏按钮（找 😀 表情按钮，用于程序化打开面板）。
        // PII 安全：只列 AXButton 控件（UI 文案，非聊天内容），且只走右侧面板（避开左侧巨表）。
        if let mainWindow = windows.first(where: { (WeChatAXProbe.copyString($0, "AXSubrole") ?? "") == "AXStandardWindow" }) ?? windows.first {
            let panelRoot = WeChatAXProbe.rightPanelRoot(window: mainWindow)
            var btns: [AXUIElement] = []
            collectButtons(panelRoot, into: &btns, cap: 100)
            let bottomFirst = btns.sorted {
                (WeChatAXProbe.frame(of: $0)?.minY ?? 0) > (WeChatAXProbe.frame(of: $1)?.minY ?? 0)
            }
            out += "\n## 右侧面板按钮（定位 😀 表情按钮用，按靠底排序，仅列 AXButton）：\n"
            if bottomFirst.isEmpty { out += "  （未找到按钮）\n" }
            for b in bottomFirst.prefix(20) { out += "  " + nodeLine(b) + "\n" }
        }

        finish(out)
    }

    /// 收集子树里的 AXButton（有 frame 者），有界遍历。
    private static func collectButtons(_ root: AXUIElement, into out: inout [AXUIElement], cap: Int) {
        var scanned = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if out.count >= cap || scanned > 8000 || depth > 50 { return }
            scanned += 1
            if WeChatAXProbe.role(el) == "AXButton", WeChatAXProbe.frame(of: el) != nil { out.append(el) }
            for c in WeChatAXProbe.children(el) { walk(c, depth + 1) }
        }
        walk(root, 0)
    }

    // MARK: - 浮层定位

    /// 在给定根集合下查找首个 role==wantRole 的节点（可要求其子树含表情标志）。
    private static func findRole(_ wantRole: String,
                                 under roots: [AXUIElement],
                                 requireMarker: Bool) -> AXUIElement? {
        for root in roots {
            if let hit = findRole(wantRole, in: root, requireMarker: requireMarker) { return hit }
        }
        return nil
    }

    private static func findRole(_ wantRole: String,
                                 in root: AXUIElement,
                                 requireMarker: Bool) -> AXUIElement? {
        var result: AXUIElement?
        var scanned = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if result != nil || scanned > 5000 || depth > 40 { return }
            scanned += 1
            if WeChatAXProbe.role(el) == wantRole,
               !requireMarker || subtreeContainsMarker(el) {
                result = el; return
            }
            for c in WeChatAXProbe.children(el) {
                walk(c, depth + 1)
                if result != nil { return }
            }
        }
        walk(root, 0)
        return result
    }

    /// 子树是否含表情面板标志文案（有界遍历，命中即停）。
    private static func subtreeContainsMarker(_ root: AXUIElement) -> Bool {
        var found = false
        var scanned = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if found || scanned > 4000 || depth > 40 { return }
            scanned += 1
            for attr in ["AXValue", "AXTitle", "AXDescription", "AXPlaceholderValue"] {
                if let s = WeChatAXProbe.copyString(el, attr),
                   markers.contains(where: { s.contains($0) }) {
                    found = true; return
                }
            }
            for c in WeChatAXProbe.children(el) {
                walk(c, depth + 1)
                if found { return }
            }
        }
        walk(root, 0)
        return found
    }

    // MARK: - 整树 dump（仅用于浮层/popover，确认 PII 安全后调用）

    private static func dumpTree(_ root: AXUIElement) -> String {
        var lines: [String] = []
        var count = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if count > 2500 || depth > 22 { return }
            count += 1
            lines.append(String(repeating: "  ", count: depth) + nodeLine(el))
            for c in WeChatAXProbe.children(el) { walk(c, depth + 1) }
        }
        walk(root, 0)
        lines.append("（共 \(count) 节点）")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 定向收集（PII 安全兜底：面板挂在主窗口下时只摘关键节点）

    private static func targetedCollect(in host: AXUIElement) -> String {
        var out: [String] = []
        var scanned = 0
        var cellSamples = 0
        var seenMarker = false
        func walk(_ el: AXUIElement, _ depth: Int) {
            if scanned > 6000 || depth > 40 { return }
            scanned += 1
            let r = WeChatAXProbe.role(el)
            let txt = ["AXValue", "AXTitle", "AXDescription", "AXPlaceholderValue"]
                .compactMap { WeChatAXProbe.copyString(el, $0) }
                .joined(separator: " ")
            if markers.contains(where: { txt.contains($0) }) {
                seenMarker = true
                out.append("  [标志] " + nodeLine(el))
            }
            if ["AXTextField", "AXTextArea", "AXSearchField"].contains(r) {
                out.append("  [文本框] " + nodeLine(el))
            }
            if seenMarker, cellSamples < 14,
               ["AXImage", "AXButton", "AXCell"].contains(r),
               WeChatAXProbe.frame(of: el) != nil {
                out.append("  [结果格?] " + nodeLine(el))
                cellSamples += 1
            }
            for c in WeChatAXProbe.children(el) { walk(c, depth + 1) }
        }
        walk(host, 0)
        return out.isEmpty
            ? "  （定向收集未发现搜索框/结果格，请确认面板已搜索后再试）\n"
            : out.joined(separator: "\n") + "\n"
    }

    // MARK: - 单节点格式化

    /// role/subrole [roleDesc] (x,y wxh) set:Value act=... id=... 「Value=… | Placeholder=…」
    private static func nodeLine(_ el: AXUIElement) -> String {
        var roleStr = WeChatAXProbe.role(el)
        if roleStr.isEmpty { roleStr = "(无Role)" }
        if let sub = WeChatAXProbe.copyString(el, "AXSubrole"), !sub.isEmpty { roleStr += "/\(sub)" }
        if let rd = WeChatAXProbe.copyString(el, "AXRoleDescription"), !rd.isEmpty { roleStr += " [\(rd)]" }

        let frameStr = WeChatAXProbe.frame(of: el).map {
            "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))"
        } ?? "(no-frame)"

        let setStr = isSettable(el, "AXValue") ? " set:Value" : ""

        let acts = actions(el)
        let actStr = acts.isEmpty ? "" : " act=" + acts.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ",")

        var idStr = ""
        if let id = WeChatAXProbe.copyString(el, "AXIdentifier"), !id.isEmpty { idStr = " id=\(id)" }

        return "\(roleStr) \(frameStr)\(setStr)\(actStr)\(idStr)\(texts(el))"
    }

    /// 拼接所有非空文本属性（截断 50 字、换行替换 ⏎），标明各属性来源。
    private static func texts(_ el: AXUIElement) -> String {
        var parts: [String] = []
        for attr in ["AXValue", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp"] {
            guard let s = WeChatAXProbe.copyString(el, attr),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var t = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "⏎")
            if t.count > 50 { t = String(t.prefix(50)) + "…" }
            parts.append("\(attr.dropFirst(2))=\(t)")
        }
        return parts.isEmpty ? "" : " 「" + parts.joined(separator: " | ") + "」"
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

    private static func axElements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    // MARK: - 输出

    private static func finish(_ content: String) {
        try? content.write(toFile: outPath, atomically: true, encoding: .utf8)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        NSLog("[StickerProbe] 完成，已写入 %@ 并复制到剪贴板（%d 字）", outPath, content.count)
    }
}
