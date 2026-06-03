import AppKit
import ApplicationServices

@MainActor
enum WeChatAXProbe {
    // 微信 Mac 可能的 bundle id（不同版本/渠道可能不同）
    static let bundleIDs = ["com.tencent.xinWeChat", "com.tencent.WeChat"]

    // AX role 字面量（避免常量类型歧义）
    private static let roleStaticText = "AXStaticText"
    private static let roleTextArea = "AXTextArea"
    private static let roleTextField = "AXTextField"

    enum ProbeError: Error, CustomStringConvertible {
        case noPermission, weChatNotRunning, noWindow
        var description: String {
            switch self {
            case .noPermission: return "未授予辅助功能权限"
            case .weChatNotRunning: return "未找到正在运行的微信"
            case .noWindow: return "拿不到微信前台窗口"
            }
        }
    }

    /// 一条消息（探针本地轻量类型，不依赖 ZhiYuCore）。
    struct Message {
        let isMe: Bool
        let text: String
    }

    /// 探针读取结果（本地轻量类型，不依赖 ZhiYuCore）。
    struct ProbeResult {
        var contactName: String
        var messages: [Message]
        var draft: String
        var inputFrame: CGRect?
        var inputFocused: Bool
        var rawLines: [String]   // 调试用：每条可见文本 + 其 x 坐标
    }

    static func findWeChatApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let byID = apps.first(where: { ($0.bundleIdentifier).map(bundleIDs.contains) ?? false }) {
            return byID
        }
        return apps.first(where: { $0.localizedName == "WeChat" || $0.localizedName == "微信" })
    }

    static func run() -> Result<ProbeResult, ProbeError> {
        guard AXIsProcessTrusted() else { return .failure(.noPermission) }
        guard let app = findWeChatApp() else { return .failure(.weChatNotRunning) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(appElement, "AXFocusedWindow")
                ?? copyElement(appElement, "AXMainWindow") else {
            return .failure(.noWindow)
        }

        let windowFrame = frame(of: window)
        var texts: [(text: String, frame: CGRect)] = []
        var input: AXUIElement?
        collect(window, texts: &texts, input: &input)

        let midX = windowFrame?.midX ?? 0
        let messages: [Message] = texts
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                let isMe = item.frame.midX > midX
                return Message(isMe: isMe, text: item.text)
            }

        let title = copyString(window, "AXTitle") ?? app.localizedName ?? "未知联系人"
        var draft = ""
        var inputFrame: CGRect?
        var inputFocused = false
        if let field = input {
            draft = copyString(field, "AXValue") ?? ""
            inputFrame = frame(of: field)
            inputFocused = copyBool(field, "AXFocused") ?? false
        }

        let rawLines = texts.map { "x=\(Int($0.frame.midX))  \($0.text)" }
        return .success(ProbeResult(contactName: title,
                                    messages: messages,
                                    draft: draft,
                                    inputFrame: inputFrame,
                                    inputFocused: inputFocused,
                                    rawLines: rawLines))
    }

    // MARK: - AX 辅助（供本类型与 InserterProbe 复用）

    static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func copyBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    static func role(_ el: AXUIElement) -> String { copyString(el, "AXRole") ?? "" }

    static func frame(of el: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sizeValue) == .success
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// 递归遍历：收集所有 AXStaticText 文本 + 坐标；记录第一个文本输入控件。
    static func collect(_ el: AXUIElement,
                        texts: inout [(text: String, frame: CGRect)],
                        input: inout AXUIElement?) {
        let r = role(el)
        if r == roleStaticText, let s = copyString(el, "AXValue"), !s.isEmpty {
            texts.append((s, frame(of: el) ?? .zero))
        }
        if input == nil, (r == roleTextArea || r == roleTextField) {
            input = el
        }
        for child in children(el) {
            collect(child, texts: &texts, input: &input)
        }
    }
}
