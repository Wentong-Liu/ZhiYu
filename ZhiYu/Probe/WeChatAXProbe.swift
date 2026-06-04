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
    private static let roleScrollArea = "AXScrollArea"
    private static let roleSplitGroup = "AXSplitGroup"
    private static let roleTable = "AXTable"
    private static let roleRow = "AXRow"
    private static let roleTableRow = "AXTableRow"

    /// 快速读取只取最后 N 行消息。
    private static let maxMessages = 30

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

    /// 说话人归属。
    enum Speaker {
        case me
        case other
        case separator  // 纯时间行 / 系统分隔，正文为时间或提示
    }

    /// 一条消息（探针本地轻量类型，不依赖 ZhiYuCore）。
    struct Message {
        let speaker: Speaker
        let name: String   // 发言人名（other 才有意义；me/separator 为空）
        let text: String   // 正文
        var isMe: Bool { speaker == .me }
    }

    /// 探针读取结果（本地轻量类型，不依赖 ZhiYuCore）。
    struct ProbeResult {
        var elapsedMs: Int          // 本次快速读取耗时（毫秒）
        var contactName: String
        var messages: [Message]
        var draft: String
        var inputFrame: CGRect?
        var inputFocused: Bool
        var diagnostics: [String]   // 定位/回退诊断信息
    }

    static func findWeChatApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let byID = apps.first(where: { ($0.bundleIdentifier).map(bundleIDs.contains) ?? false }) {
            return byID
        }
        return apps.first(where: { $0.localizedName == "WeChat" || $0.localizedName == "微信" })
    }

    /// 【共享唤醒助手】对 app 元素设置 AXManualAccessibility / AXEnhancedUserInterface。
    /// 这是两个便宜的 set 调用，不做整树遍历。保留以兼容不同版本；失败容错，不 crash。
    @discardableResult
    static func wakeAccessibility(_ appElement: AXUIElement) -> [String] {
        let r1 = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return [
            "AXManualAccessibility set -> \(r1.rawValue)",
            "AXEnhancedUserInterface set -> \(r2.rawValue)",
        ]
    }

    // MARK: - 快速读取（供「运行 AX 探针」按钮）

    /// 快速读取路径：只导航右侧会话面板，绝不进入左侧会话列表那张巨表。
    /// 步骤见实现内注释。健壮性：定位不到时不崩溃，输出诊断并回退。
    static func run() -> Result<ProbeResult, ProbeError> {
        let t0 = ProcessInfo.processInfo.systemUptime

        guard AXIsProcessTrusted() else { return .failure(.noPermission) }
        guard let app = findWeChatApp() else { return .failure(.weChatNotRunning) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // 便宜的两个 set 调用（无整树遍历），兼容部分版本的建树需求。
        wakeAccessibility(appElement)

        // a. focusedWindow
        guard let window = copyElement(appElement, "AXFocusedWindow")
                ?? copyElement(appElement, "AXMainWindow") else {
            return .failure(.noWindow)
        }

        var diagnostics: [String] = []

        // b. 主 AXSplitGroup -> 其【直接子节点】里的右侧会话面板 AXSplitGroup。
        //    全程不进入左侧会话列表的 AXScrollArea/AXTable（它是主 split group 的另一个子节点）。
        let rightPanel = locateRightPanel(window: window, diagnostics: &diagnostics)

        // 没定位到右侧面板：回退（不崩溃），仍返回耗时与诊断。
        guard let panel = rightPanel else {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return .success(ProbeResult(
                elapsedMs: elapsed,
                contactName: copyString(window, "AXTitle") ?? app.localizedName ?? "未知联系人",
                messages: [],
                draft: "",
                inputFrame: nil,
                inputFocused: false,
                diagnostics: diagnostics))
        }

        // c. 在右侧面板小子树里定位三个目标。
        let messageTable = locateMessageTable(in: panel)
        let composer = locateComposerInPanel(panel)
        let title = locateContactTitle(in: panel)
            ?? copyString(window, "AXTitle")
            ?? app.localizedName
            ?? "未知联系人"

        // d/e. 读消息：遍历消息表的行（文档顺序=时间顺序），只取最后 N 行，只读 AXValue 并解析说话人。
        var messages: [Message] = []
        if let table = messageTable {
            messages = readMessages(from: table, diagnostics: &diagnostics)
        } else {
            diagnostics.append("未定位到消息列表（结构可能已变），请用『完整结构树（诊断·慢）』诊断")
        }

        // f. composer：读 AXValue=草稿、frame、AXFocused。
        var draft = ""
        var inputFocused = false
        var inputFrame: CGRect? = nil
        if let c = composer {
            draft = copyString(c, "AXValue") ?? ""
            inputFocused = copyBool(c, "AXFocused") ?? false
            inputFrame = frame(of: c)
        } else {
            diagnostics.append("未定位到输入框 composer（结构可能已变）")
        }

        // g. 计时。
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)

        return .success(ProbeResult(
            elapsedMs: elapsed,
            contactName: title,
            messages: messages,
            draft: draft,
            inputFrame: inputFrame,
            inputFocused: inputFocused,
            diagnostics: diagnostics))
    }

    /// 定位右侧会话面板：
    /// 1) 在窗口浅层子节点里找 role==AXSplitGroup 的主 split group。
    /// 2) 在主 split group 的【直接子节点】里找 role==AXSplitGroup 的那个作为右侧面板。
    /// 绝不下钻左侧会话列表的 AXScrollArea/AXTable（即主 split group 的另一个子节点）。
    private static func locateRightPanel(window: AXUIElement,
                                         diagnostics: inout [String]) -> AXUIElement? {
        // 浅层查找主 split group：窗口直接子节点优先；个别版本可能再包一层，限深度 3 的浅查。
        guard let mainSplit = findSplitGroupShallow(window, depth: 0, maxDepth: 3) else {
            diagnostics.append("未定位到主 AXSplitGroup（结构可能已变），请用『完整结构树（诊断·慢）』诊断")
            return nil
        }

        // 主 split group 的直接子节点里找 AXSplitGroup。可能有多个，取 minX 最大（最靠右）的那个。
        let directChildren = children(mainSplit)
        let nestedSplits = directChildren.filter { role($0) == roleSplitGroup }
        guard !nestedSplits.isEmpty else {
            diagnostics.append("未在主 AXSplitGroup 直接子节点中找到右侧面板 AXSplitGroup（结构可能已变），请用『完整结构树（诊断·慢）』诊断")
            return nil
        }
        // 右侧面板应是 minX 最大者（x≈359 vs 左侧≈106）。读 frame 仅对这几个候选做，开销可忽略。
        let panel = nestedSplits.max(by: { (frame(of: $0)?.minX ?? 0) < (frame(of: $1)?.minX ?? 0) })
        return panel ?? nestedSplits.first
    }

    /// 浅层查找第一个 AXSplitGroup（限深度，不会进入巨表，因为巨表在 split group 内部）。
    private static func findSplitGroupShallow(_ el: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        if role(el) == roleSplitGroup { return el }
        guard depth < maxDepth else { return nil }
        for child in children(el) {
            // 只在尚未命中 split group 的浅层结构里下钻；命中后立刻返回，不会进入其内部巨表。
            if let found = findSplitGroupShallow(child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// 在右侧面板小子树里定位消息列表：含 AXTable 的 AXScrollArea -> 其内的 AXTable。
    /// 右侧面板是小子树，有界遍历安全。
    private static func locateMessageTable(in panel: AXUIElement) -> AXUIElement? {
        var visited = 0
        // 先找直接/浅层 AXScrollArea，其子树里含 AXTable 的就是消息列表。
        return findMessageTable(panel, depth: 0, visited: &visited)
    }

    private static func findMessageTable(_ el: AXUIElement, depth: Int, visited: inout Int) -> AXUIElement? {
        guard depth < 40, visited < 2000 else { return nil }
        visited += 1
        if role(el) == roleScrollArea {
            // 在这个 scroll area 子树里找 AXTable。
            if let table = findFirstTable(el, depth: 0, visited: &visited) {
                return table
            }
        }
        for child in children(el) {
            if let table = findMessageTable(child, depth: depth + 1, visited: &visited) {
                return table
            }
        }
        return nil
    }

    private static func findFirstTable(_ el: AXUIElement, depth: Int, visited: inout Int) -> AXUIElement? {
        guard depth < 20, visited < 2000 else { return nil }
        visited += 1
        if role(el) == roleTable { return el }
        for child in children(el) {
            if let table = findFirstTable(child, depth: depth + 1, visited: &visited) {
                return table
            }
        }
        return nil
    }

    /// 联系人标题：右侧面板顶部的 AXStaticText。取 minY 最小（最靠上）且非空者。
    private static func locateContactTitle(in panel: AXUIElement) -> String? {
        var candidates: [(text: String, minY: CGFloat)] = []
        var visited = 0
        collectTopStaticTexts(panel, depth: 0, visited: &visited, into: &candidates)
        guard !candidates.isEmpty else { return nil }
        // 顶部标题 = minY 最小。
        let title = candidates.min(by: { $0.minY < $1.minY })?.text
        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收集右侧面板里的 AXStaticText（不进入消息表与滚动区，避免噪声/开销）。
    private static func collectTopStaticTexts(_ el: AXUIElement,
                                              depth: Int,
                                              visited: inout Int,
                                              into out: inout [(text: String, minY: CGFloat)]) {
        guard depth < 12, visited < 400 else { return }
        visited += 1
        let r = role(el)
        // 不下钻 ScrollArea/Table（消息列表、输入区滚动），标题是面板直挂的 AXStaticText。
        if r == roleScrollArea || r == roleTable { return }
        if r == roleStaticText, let s = copyString(el, "AXValue"),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append((s, frame(of: el)?.minY ?? .greatestFiniteMagnitude))
        }
        for child in children(el) {
            collectTopStaticTexts(child, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    /// 在右侧面板里用统一规则定位 composer（与读取口径一致，复用 collectEditables/pickComposer）。
    private static func locateComposerInPanel(_ panel: AXUIElement) -> AXUIElement? {
        let editables = collectEditables(panel)
        return pickComposer(from: editables)?.element
    }

    /// 读消息：优先按 AXRow/AXTableRow 直接行读取；若拿不到行（AppKit 表格有时把行挂在 AXColumn 下，
    /// 或 AXChildren 不直接给行），则在表子树内按文档顺序收集叶子非空 AXValue 兜底（表子树小，开销可接受）。
    /// 只读 AXValue，解析说话人，取最后 N 行。
    private static func readMessages(from table: AXUIElement, diagnostics: inout [String]) -> [Message] {
        let allChildren = children(table)
        let rows = allChildren.filter {
            let r = role($0)
            return r == roleRow || r == roleTableRow
        }
        var rawValues: [String] = []
        for row in rows {
            if let value = firstNonEmptyValue(in: row, depth: 0) { rawValues.append(value) }
        }
        var usedFallback = false
        if rawValues.isEmpty {
            usedFallback = true
            var visited = 0
            collectLeafValues(table, depth: 0, visited: &visited, into: &rawValues)
        }
        diagnostics.append("消息表: 子节点=\(allChildren.count) 行=\(rows.count) 取值=\(rawValues.count)\(usedFallback ? "(兜底)" : "")")
        let parsed = rawValues.map { parseMessage($0) }
        return parsed.count > maxMessages ? Array(parsed.suffix(maxMessages)) : parsed
    }

    /// 表子树内按文档顺序收集叶子节点的非空 AXValue（跳过 AXColumn/滚动条避免与行重复）。
    private static func collectLeafValues(_ el: AXUIElement, depth: Int, visited: inout Int, into out: inout [String]) {
        guard depth < 24, visited < 6000 else { return }
        visited += 1
        let r = role(el)
        if r == "AXColumn" || r == "AXScrollBar" { return }
        let kids = children(el)
        if kids.isEmpty {
            if let v = bestText(el) {
                out.append(v)
            }
            return
        }
        for k in kids {
            collectLeafValues(k, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    /// 行内下钻到第一个含非空 AXValue 的叶子，只读 AXValue。
    private static func firstNonEmptyValue(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 12 else { return nil }
        if let v = bestText(el) {
            return v
        }
        for child in children(el) {
            if let v = firstNonEmptyValue(in: child, depth: depth + 1) {
                return v
            }
        }
        return nil
    }

    // MARK: - 说话人 / 正文解析

    /// 解析一条消息 value：
    /// - 以 "我说:" 或 "我:" 开头 -> me，正文=分隔符之后。
    /// - 否则匹配 "^(.+?)说[:：]" 或 "^(.+?)[:：]" -> other，name=捕获，正文=分隔符之后。
    /// - 纯时间行 / 空 -> separator。
    /// 冒号兼容半角 : 与全角 ：。
    static func parseMessage(_ raw: String) -> Message {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return Message(speaker: .separator, name: "", text: raw)
        }

        // 纯时间 / 日期分隔行：02:33 / 03:03 / 昨天 20:38 / 上午 9:41 等。
        if isTimeSeparator(value) {
            return Message(speaker: .separator, name: "", text: value)
        }

        // 我说: / 我:（半/全角冒号）
        for prefix in ["我说:", "我说：", "我:", "我："] {
            if value.hasPrefix(prefix) {
                let body = String(value.dropFirst(prefix.count))
                return Message(speaker: .me, name: "", text: body)
            }
        }

        // 对方：^(.+?)说[:：]  优先，其次 ^(.+?)[:：]
        if let (name, body) = matchSpeaker(value, pattern: "^(.+?)说[:：](.*)$")
            ?? matchSpeaker(value, pattern: "^(.+?)[:：](.*)$") {
            return Message(speaker: .other, name: name, text: body)
        }

        // 无分隔符：无法解析说话人，按 other 整条作为正文，name 留空。
        return Message(speaker: .other, name: "", text: value)
    }

    /// 用正则取捕获组 1=name、组 2=body（已 trim）。
    private static func matchSpeaker(_ value: String, pattern: String) -> (name: String, body: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let m = regex.firstMatch(in: value, options: [], range: range),
              m.numberOfRanges >= 3,
              let nameRange = Range(m.range(at: 1), in: value),
              let bodyRange = Range(m.range(at: 2), in: value) else { return nil }
        let name = String(value[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(value[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (name, body)
    }

    /// 判断纯时间 / 日期分隔行（如 "02:33" / "03:03" / "昨天 20:38" / "上午 9:41" / "星期三 下午 3:20"）。
    private static func isTimeSeparator(_ value: String) -> Bool {
        let pattern = "^(昨天|前天|今天|上午|下午|凌晨|早上|中午|晚上|星期[一二三四五六日天]|周[一二三四五六日天]|[0-9]{1,4}[年/月-]|[\\s])*[0-9]{1,2}[:：][0-9]{2}$"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if regex.firstMatch(in: value, options: [], range: range) != nil { return true }
        }
        return false
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

    /// 依次尝试多个文本属性，返回首个非空。
    /// 微信消息气泡文字在 AXTitle/AXDescription 而非 AXValue（输入框草稿才在 AXValue）。
    static func bestText(_ el: AXUIElement) -> String? {
        for attr in ["AXValue", "AXTitle", "AXDescription"] {
            if let s = copyString(el, attr),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
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

    // MARK: - 临时诊断（排查"图片/表情"消息的 AX 结构与 frame，确认后删）

    /// 导出消息表最后 12 行：每个节点的 role + frame + AXValue/AXTitle/AXDescription。
    static func dumpMessageRows() -> [String] {
        guard AXIsProcessTrusted() else { return ["未授予辅助功能权限"] }
        guard let app = findWeChatApp() else { return ["未找到微信"] }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        _ = wakeAccessibility(appEl)
        guard let window = copyElement(appEl, "AXFocusedWindow") ?? copyElement(appEl, "AXMainWindow") else {
            return ["拿不到窗口"]
        }
        var diag: [String] = []
        guard let panel = locateRightPanel(window: window, diagnostics: &diag) else {
            return diag + ["没定位到右侧面板"]
        }
        guard let table = locateMessageTable(in: panel) else {
            return diag + ["没定位到消息表"]
        }
        let rows = children(table).filter { let r = role($0); return r == roleRow || r == roleTableRow }
        var out: [String] = ["消息行数: \(rows.count)（导出最后 12 行）"]
        for (i, row) in Array(rows.suffix(12)).enumerated() {
            out.append("—— row \(i) ——")
            dumpNodeAttrs(row, depth: 0, into: &out)
        }
        return out
    }

    private static func dumpNodeAttrs(_ el: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 8 else { return }
        let pad = String(repeating: "  ", count: depth)
        func attr(_ a: String) -> String {
            let s = copyString(el, a) ?? ""
            return s.isEmpty ? "" : String(s.prefix(60)).replacingOccurrences(of: "\n", with: "⏎")
        }
        let f = frame(of: el).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-"
        out.append("\(pad)\(role(el)) \(f) | V=「\(attr("AXValue"))」 T=「\(attr("AXTitle"))」 D=「\(attr("AXDescription"))」")
        for c in children(el) { dumpNodeAttrs(c, depth: depth + 1, into: &out) }
    }

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

    /// 可编辑元素候选：保留 AXUIElement 引用，供后续读 AXValue/AXFocused 或写入复用。
    struct Editable {
        let element: AXUIElement
        let role: String
        let frame: CGRect
    }

    /// 递归收集所有可编辑元素(AXTextArea/AXTextField)，保留元素引用 + frame。复用 frame(of:) 的安全类型守卫。
    /// 注意：调用方应传入右侧面板小子树根，避免遍历整窗口（左侧巨表）。
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

    /// 【写入路径用】定位右侧会话面板根（供 InserterProbe.locateComposer 复用，口径与快速读取一致）。
    /// 找不到则回退到窗口本身（至少不返回 nil，让上层用 collectEditables 兜底）。
    static func rightPanelRoot(window: AXUIElement) -> AXUIElement {
        var diag: [String] = []
        return locateRightPanel(window: window, diagnostics: &diag) ?? window
    }

    // MARK: - 完整结构树 dump（诊断·慢，单独按钮专用，正常路径不调用）

    /// 全树结构 dump：缩进(depth) + AXRole(+AXSubrole) + frame + (AXValue 或 AXTitle，截断 40 字，换行替换 ⏎)。
    /// 深度上限 60、节点上限 2000，防止爆栈/爆量。会遍历左侧巨表，仅供诊断手动触发。
    static func dumpFullTree() -> Result<[String], ProbeError> {
        guard AXIsProcessTrusted() else { return .failure(.noPermission) }
        guard let app = findWeChatApp() else { return .failure(.weChatNotRunning) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        wakeAccessibility(appElement)
        guard let window = copyElement(appElement, "AXFocusedWindow")
                ?? copyElement(appElement, "AXMainWindow") else {
            return .failure(.noWindow)
        }
        var lines: [String] = []
        var nodeCount = 0
        dumpTree(window, depth: 0, lines: &lines, nodeCount: &nodeCount)
        return .success(lines)
    }

    private static func dumpTree(_ el: AXUIElement,
                                 depth: Int,
                                 lines: inout [String],
                                 nodeCount: inout Int) {
        guard nodeCount < 2000, depth < 60 else { return }
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
