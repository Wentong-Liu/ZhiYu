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
}
