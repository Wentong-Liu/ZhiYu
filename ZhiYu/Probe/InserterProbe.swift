import AppKit
import ApplicationServices

@MainActor
enum InserterProbe {
    /// 用 AX 直接把文本设进微信输入框。返回是否成功。
    static func setText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = WeChatAXProbe.copyElement(appElement, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appElement, "AXMainWindow") else { return false }
        var texts: [(text: String, frame: CGRect)] = []
        var input: AXUIElement?
        WeChatAXProbe.collect(window, texts: &texts, input: &input)
        guard let field = input else { return false }
        return AXUIElementSetAttributeValue(field, "AXValue" as CFString, text as CFString) == .success
    }

    /// 兜底：写剪贴板 + 模拟 ⌘V 粘贴到当前焦点（用后恢复原剪贴板）。
    static func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        WeChatAXProbe.findWeChatApp()?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            postKey(9, flags: .maskCommand)            // 'v'
            if let saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    pb.clearContents(); pb.setString(saved, forType: .string)
                }
            }
        }
    }

    /// 模拟回车发送。
    static func sendReturn() {
        postKey(36, flags: [])                          // Return
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
