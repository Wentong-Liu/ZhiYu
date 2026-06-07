import AppKit
import ApplicationServices

@MainActor
enum InserterProbe {
    /// 虚拟键码（macOS ANSI 键盘）：Return，供模拟回车复用。
    private static let keyCodeReturn: CGKeyCode = 36

    /// 用 AX 直接把文本设进微信输入框。返回是否成功。
    /// 与探针读取口径一致：复用 collectEditables + pickComposer 定位底部消息输入框，
    /// 不再取 collect() 抓到的第一个可编辑元素（很可能是左上角搜索框）。
    static func setText(_ text: String) -> Bool {
        guard let field = locateComposer() else { return false }
        return AXUIElementSetAttributeValue(field, AXAttr.value as CFString, text as CFString) == .success
    }

    /// 定位微信消息输入框 composer（读/写共用同一规则）。
    /// 在 AXUIElementCreateApplication 之后、定位 composer 之前先调用共享唤醒助手一次（两个便宜的 set 调用）。
    /// 与快速读取口径一致：先定界到右侧会话面板再 collectEditables，避免遍历左侧会话列表巨表（性能元凶）。
    static func locateComposer() -> AXUIElement? {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        WeChatAXProbe.wakeAccessibility(appElement)
        guard let window = WeChatAXProbe.focusedOrMainWindow(of: appElement) else { return nil }
        let root = WeChatAXProbe.rightPanelRoot(window: window)
        let editables = WeChatAXProbe.collectEditables(root)
        return WeChatAXProbe.pickComposer(from: editables)?.element
    }

    /// 读取当前 composer 的 AXValue，用于写入后校验。
    static func composerValue() -> String? {
        guard let field = locateComposer() else { return nil }
        return WeChatAXProbe.copyString(field, AXAttr.value)
    }

    /// 读取当前 composer 的 AXFocused，用于回车前确认键盘焦点是否真正落在输入框。
    /// 部分实现可能不暴露该属性（返回 nil）：调用方把 nil 视为未知、回退 false，由前台 active/frontmost 兜底。
    static func composerFocused() -> Bool? {
        guard let field = locateComposer() else { return nil }
        return WeChatAXProbe.copyBool(field, AXAttr.focused)
    }

    /// 回车前的前台/焦点二次校验：activate() 是异步 fire-and-forget，AXValue 写入成功不代表
    /// 微信已是前台键盘焦点持有者；这里显式校验「微信已在前台」，并尽量结合 composer AXFocused。
    /// 满足任一强信号即视为可回车：
    /// - 微信进程 isActive（NSWorkspace.frontmostApplication 即微信）—— 前台已落定的权威信号；
    /// - composer AXFocused == true —— 输入框已持有键盘焦点。
    /// 二者都拿不到肯定信号时返回 false，调用方应放弃回车以免事件进错窗口导致整条不发送。
    static func isWeChatFrontFocused() -> Bool {
        let appActive = WeChatAXProbe.findWeChatApp()?.isActive ?? false
        // 复用统一身份判定（bundle id + 本地化名兜底），与 WeChatAXProbe.isWeChat 同口径。
        let frontIsWeChat = NSWorkspace.shared.frontmostApplication
            .map(WeChatAXProbe.isWeChat) ?? false
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
        _ = AXUIElementSetAttributeValue(composer, AXAttr.focused as CFString, kCFBooleanTrue)
        WeChatAXProbe.findWeChatApp()?.activate()
        return true
    }

    /// 模拟回车发送。返回是否成功投递（down/up 两个 CGEvent 都成功创建并 post）。
    @discardableResult
    static func sendReturn() -> Bool {
        postKey(keyCodeReturn, flags: [])               // Return
    }

    /// 投递一对 keyDown/keyUp 的 CGEvent（正常成功路径行为不变：照常 .cghidEventTap post）。
    /// 返回是否成功投递：CGEventSource / down / up 任一为 nil（系统未能建事件）时，
    /// 回车不会真正发出——过去此处静默丢失，现补一条 NSLog + 一声 NSSound.beep，并返回 false。
    @discardableResult
    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        guard let down, let up else {
            NSLog("[ZhiYu] postKey 失败：CGEvent 创建为 nil(src=%@ down=%@ up=%@)，回车未发出",
                  src == nil ? "nil" : "ok", down == nil ? "nil" : "ok", up == nil ? "nil" : "ok")
            NSSound.beep()
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
