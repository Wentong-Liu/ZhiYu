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
        var rawLines: [String]      // 调试用：每条可见文本 + 其 x 坐标
        var wakeLines: [String]     // 唤醒可访问性的 rawValue 结果
        var candidateLines: [String]  // 所有候选输入框 role + frame
        var composerLine: String   // 选中的 composer 描述
        var treeLines: [String]    // 完整结构树 dump
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

        // 【唤醒可访问性】微信 4.x 疑似 Electron/Chromium 系，AX 树默认折叠。
        // 对 app 元素设置 AXManualAccessibility / AXEnhancedUserInterface 触发建树。
        // 失败容错，仅记录 rawValue，不 crash。唤醒可能异步：首次点击可能只唤醒，需再点一次。
        let r1 = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let wakeLines = [
            "AXManualAccessibility set -> \(r1.rawValue)",
            "AXEnhancedUserInterface set -> \(r2.rawValue)",
        ]

        guard let window = copyElement(appElement, "AXFocusedWindow")
                ?? copyElement(appElement, "AXMainWindow") else {
            return .failure(.noWindow)
        }

        let windowFrame = frame(of: window)
        var texts: [(text: String, frame: CGRect)] = []
        var input: AXUIElement?
        collect(window, texts: &texts, input: &input)

        // 【候选输入框收集 + composer 定位】不再取"第一个 TextField/TextArea"（会撞左上角搜索框）。
        // 收集全部可编辑元素，选 minY 最大（最靠底部）且宽度足够的作为消息输入框 composer。
        let editables = collectEditables(window)
        let composer = pickComposer(from: editables)
        let candidateLines: [String] = editables.isEmpty
            ? ["(无可编辑元素)"]
            : editables.map { fmtFrame(role: $0.role, frame: $0.frame) }
        let composerLine = composer.map { fmtFrame(role: $0.role, frame: $0.frame) } ?? "(未定位到 composer)"

        // 【全树结构 dump】对 focusedWindow 子树逐节点输出，深度/节点数有上限防爆。
        var treeLines: [String] = []
        var nodeCount = 0
        dumpTree(window, depth: 0, lines: &treeLines, nodeCount: &nodeCount)

        // 【Phase 1 已知局限 / 待 Phase 2 解决】
        // collect() 不加区域约束地收集窗口内全部 AXStaticText，这里再把它们一律映射为 Message
        // 并按 midX 分左右。微信窗口的左侧会话列表项、联系人名、时间戳、"以下为新消息"等系统文本
        // 同样是 AXStaticText，会被误当作消息混入，且其 x 位置会被错误标注 me/other（spec 5.1/8 标注的
        // 最高风险：说话人归属准确率需实测）。Phase 1 探针只验证可行性，rawLines 输出 x 坐标供人工判读，
        // 该污染在收尾结论里如实记录即可。Phase 2 WeChatReader 应：先定位聊天消息列表容器
        // (AXScrollArea/AXTable 等) 再在其子树内收集 AXStaticText，排除侧栏/标题栏；说话人区分改用
        // 气泡容器(消息行)的 frame 而非纯文本 midX，可显著降噪。
        let midX = windowFrame?.midX ?? 0
        let messages: [Message] = texts
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                let isMe = item.frame.midX > midX
                return Message(isMe: isMe, text: item.text)
            }

        let title = copyString(window, "AXTitle") ?? app.localizedName ?? "未知联系人"
        // 读/写口径统一：draft/focus 都从选中的 composer 元素读取，而非 collect() 抓到的第一个
        // 可编辑元素（很可能是左上角搜索框）。无 composer 时回退到旧 input，至少不报告空。
        let composerElement = composer?.element ?? input
        let inputFrame: CGRect? = composer?.frame ?? input.flatMap { frame(of: $0) }
        var draft = ""
        var inputFocused = false
        if let field = composerElement {
            draft = copyString(field, "AXValue") ?? ""
            inputFocused = copyBool(field, "AXFocused") ?? false
        }

        let rawLines = texts.map { "x=\(Int($0.frame.midX))  \($0.text)" }
        return .success(ProbeResult(contactName: title,
                                    messages: messages,
                                    draft: draft,
                                    inputFrame: inputFrame,
                                    inputFocused: inputFocused,
                                    rawLines: rawLines,
                                    wakeLines: wakeLines,
                                    candidateLines: candidateLines,
                                    composerLine: composerLine,
                                    treeLines: treeLines))
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
        // 仅校验 .success 不够：某些元素/微信版本可能返回 nil 或非 AXValue 包装类型，
        // force-cast 会运行期崩溃。先校验 CFTypeID == AXValueGetTypeID() 再转换。
        guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &posValue) == .success,
              let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sizeValue) == .success,
              let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        let posV = pv as! AXValue   // 已校验类型，转换安全
        let sizeV = sv as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue 返回 false 表示取值失败（类型不匹配），此时返回 nil 而非沿用 .zero。
        guard AXValueGetValue(posV, .cgPoint, &point),
              AXValueGetValue(sizeV, .cgSize, &size) else { return nil }
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

    /// 可编辑元素候选：保留 AXUIElement 引用，供后续读 AXValue/AXFocused 或写入复用。
    struct Editable {
        let element: AXUIElement
        let role: String
        let frame: CGRect
    }

    /// 递归收集所有可编辑元素(AXTextArea/AXTextField)，保留元素引用 + frame。复用 frame(of:) 的安全类型守卫。
    static func collectEditables(_ el: AXUIElement) -> [Editable] {
        var out: [Editable] = []
        collectEditables(el, into: &out, depth: 0)
        return out
    }

    private static func collectEditables(_ el: AXUIElement,
                                         into out: inout [Editable],
                                         depth: Int) {
        guard depth < 60 else { return }
        let r = role(el)
        if r == roleTextArea || r == roleTextField, let f = frame(of: el) {
            out.append(Editable(element: el, role: r, frame: f))
        }
        for child in children(el) {
            collectEditables(child, into: &out, depth: depth + 1)
        }
    }

    /// 统一的 composer 定位：选 minY 最大（最靠底部）且宽度足够的可编辑元素作为消息输入框，
    /// 排除左上角窄搜索框。读(draft/focus)与写(setText)共用此规则，保证口径一致。
    static func pickComposer(from editables: [Editable]) -> Editable? {
        let minComposerWidth: CGFloat = 120  // 宽度门槛，排除窄搜索框等
        return editables
            .filter { $0.frame.width >= minComposerWidth }
            .max(by: { $0.frame.minY < $1.frame.minY })
            ?? editables.max(by: { $0.frame.minY < $1.frame.minY })
    }

    /// 格式化：role(+subrole) + frame。
    private static func fmtFrame(role: String, frame: CGRect) -> String {
        "\(role)  (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))"
    }

    /// 全树结构 dump：缩进(depth) + AXRole(+AXSubrole) + frame + (AXValue 或 AXTitle，截断 40 字，换行替换 ⏎)。
    /// 深度上限 60、节点上限 1200，防止爆栈/爆量。
    static func dumpTree(_ el: AXUIElement,
                         depth: Int,
                         lines: inout [String],
                         nodeCount: inout Int) {
        guard nodeCount < 1200, depth < 60 else { return }
        nodeCount += 1

        let r = role(el)
        var roleStr = r.isEmpty ? "(无Role)" : r
        if let sub = copyString(el, "AXSubrole"), !sub.isEmpty {
            roleStr += "/\(sub)"
        }

        let frameStr: String
        if let f = frame(of: el) {
            frameStr = "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
        } else {
            frameStr = "(no-frame)"
        }

        // 优先 AXValue，否则 AXTitle。
        var label = ""
        if let v = copyString(el, "AXValue"), !v.isEmpty {
            label = v
        } else if let t = copyString(el, "AXTitle"), !t.isEmpty {
            label = t
        }
        if !label.isEmpty {
            label = label.replacingOccurrences(of: "\n", with: "⏎")
                         .replacingOccurrences(of: "\r", with: "⏎")
            if label.count > 40 {
                label = String(label.prefix(40)) + "…"
            }
            label = "  「\(label)」"
        }

        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)\(roleStr) \(frameStr)\(label)")

        for child in children(el) {
            dumpTree(child, depth: depth + 1, lines: &lines, nodeCount: &nodeCount)
        }
    }
}
