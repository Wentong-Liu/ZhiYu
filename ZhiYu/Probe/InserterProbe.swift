import AppKit
import ApplicationServices

@MainActor
enum InserterProbe {
    /// 虚拟键码（macOS ANSI 键盘）：'v' 与 Return，供模拟粘贴/回车复用。
    private static let keyCodeV: CGKeyCode = 9
    private static let keyCodeReturn: CGKeyCode = 36

    /// 用 AX 直接把文本设进微信输入框。返回是否成功。
    /// 与探针读取口径一致：复用 collectEditables + pickComposer 定位底部消息输入框，
    /// 不再取 collect() 抓到的第一个可编辑元素（很可能是左上角搜索框）。
    static func setText(_ text: String) -> Bool {
        guard let field = locateComposer() else { return false }
        return AXUIElementSetAttributeValue(field, "AXValue" as CFString, text as CFString) == .success
    }

    /// 定位微信消息输入框 composer（读/写共用同一规则）。
    /// 在 AXUIElementCreateApplication 之后、定位 composer 之前先调用共享唤醒助手一次（两个便宜的 set 调用）。
    /// 与快速读取口径一致：先定界到右侧会话面板再 collectEditables，避免遍历左侧会话列表巨表（性能元凶）。
    static func locateComposer() -> AXUIElement? {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appElement)
        guard let window = WeChatAXProbe.copyElement(appElement, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appElement, "AXMainWindow") else { return nil }
        let root = WeChatAXProbe.rightPanelRoot(window: window)
        let editables = WeChatAXProbe.collectEditables(root)
        return WeChatAXProbe.pickComposer(from: editables)?.element
    }

    /// 读取当前 composer 的 AXValue，用于写入后校验。
    static func composerValue() -> String? {
        guard let field = locateComposer() else { return nil }
        return WeChatAXProbe.copyString(field, "AXValue")
    }

    /// 读取当前 composer 的 AXFocused，用于回车前确认键盘焦点是否真正落在输入框。
    /// 部分实现可能不暴露该属性（返回 nil），调用方据此做容错（nil 不等于 false，需结合前台校验）。
    static func composerFocused() -> Bool? {
        guard let field = locateComposer() else { return nil }
        return WeChatAXProbe.copyBool(field, "AXFocused")
    }

    /// 回车前的前台/焦点二次校验：activate() 是异步 fire-and-forget，AXValue 写入成功不代表
    /// 微信已是前台键盘焦点持有者；这里显式校验「微信已在前台」，并尽量结合 composer AXFocused。
    /// 满足任一强信号即视为可回车：
    /// - 微信进程 isActive（NSWorkspace.frontmostApplication 即微信）—— 前台已落定的权威信号；
    /// - composer AXFocused == true —— 输入框已持有键盘焦点。
    /// 二者都拿不到肯定信号时返回 false，调用方应放弃回车以免事件进错窗口导致整条不发送。
    static func isWeChatFrontFocused() -> Bool {
        let appActive = WeChatAXProbe.findWeChatApp()?.isActive ?? false
        let frontIsWeChat = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.bundleIdentifier }
            .map { WeChatAXProbe.bundleIDs.contains($0) } ?? false
        let focused = composerFocused() ?? false
        return appActive || frontIsWeChat || focused
    }

    /// AX 写入后用于发送前的「激活 + 聚焦」：
    /// - locateComposer() 拿到底部 composer 元素；
    /// - 对其设 AXFocused = true 让输入框获得键盘焦点（容错：部分实现不支持该属性，
    ///   返回非 .success 不视为失败、不崩溃，仅靠激活 + 既有焦点兜底）；
    /// - findWeChatApp()?.activate() 把微信切到前台，使后续 sendReturn 的回车进入微信而非探针窗口。
    /// 返回是否成功拿到 composer 元素（拿不到说明定位失败，调用方应避免回车）。
    @discardableResult
    static func focusComposerAndActivate() -> Bool {
        guard let composer = locateComposer() else {
            // 拿不到 composer 也至少把微信切前台，便于排查。
            WeChatAXProbe.findWeChatApp()?.activate()
            return false
        }
        // AXFocused 设置可能返回 kAXErrorAttributeUnsupported 等错误，容错处理。
        _ = AXUIElementSetAttributeValue(composer, "AXFocused" as CFString, kCFBooleanTrue)
        WeChatAXProbe.findWeChatApp()?.activate()
        return true
    }

    /// 兜底：写剪贴板 + 模拟 ⌘V 粘贴到当前焦点（用后恢复原剪贴板）。
    /// completion 在 ⌘V 事件 post 之后触发——调用方（如 pasteAndSend）应在该回调里再
    /// 延时回车，而不是用一个与本函数内部 0.25s 解耦的独立计时器。回调在主线程执行。
    static func pasteText(_ text: String, completion: (() -> Void)? = nil) {
        let pb = NSPasteboard.general
        // 完整保存原剪贴板内容（遍历所有 item 的所有 type 存为 Data），
        // 避免只处理 .string 时把用户原本的图片/RTF/文件 URL 等内容破坏掉。
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        WeChatAXProbe.findWeChatApp()?.activate()
        // 记录粘贴前的 changeCount，恢复前确认粘贴已被消费，降低 ⌘V 粘到旧内容 / 过早恢复的竞态。
        let changeCountBeforePaste = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            postKey(keyCodeV, flags: .maskCommand)     // 'v'
            restoreSnapshotWhenSafe(saved, into: pb, pasteWriteChangeCount: changeCountBeforePaste)
            completion?()
        }
    }

    /// 在确认粘贴已被目标消费后再恢复原剪贴板，最多重试若干次后兜底恢复。
    private static func restoreSnapshotWhenSafe(_ saved: [[String: Data]],
                                                into pb: NSPasteboard,
                                                pasteWriteChangeCount: Int,
                                                attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // changeCount 变化或重试上限到达后再恢复：尽量保证 ⌘V 已读取我们写入的内容。
            if pb.changeCount != pasteWriteChangeCount || attempt >= 4 {
                restore(saved, into: pb)
            } else {
                restoreSnapshotWhenSafe(saved, into: pb,
                                        pasteWriteChangeCount: pasteWriteChangeCount,
                                        attempt: attempt + 1)
            }
        }
    }

    /// 把剪贴板内每个 item 的全部 type 存成 Data，便于无损恢复。
    private static func snapshot(_ pb: NSPasteboard) -> [[String: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        }
    }

    /// 还原 snapshot；若原本为空则不清空用户当前剪贴板，避免数据破坏型副作用。
    private static func restore(_ saved: [[String: Data]], into pb: NSPasteboard) {
        let nonEmpty = saved.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }   // 原本无内容：不动用户剪贴板
        pb.clearContents()
        let items: [NSPasteboardItem] = nonEmpty.map { dict in
            let item = NSPasteboardItem()
            for (typeRaw, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// 模拟回车发送。
    static func sendReturn() {
        postKey(keyCodeReturn, flags: [])               // Return
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
