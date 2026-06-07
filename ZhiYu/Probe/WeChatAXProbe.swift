import AppKit
import ApplicationServices
import ZhiYuCore

/// 非隔离：run() 及其调用链只做 AX C-API 读取 + NSRunningApplication 查询（线程安全），
/// 全部 static 成员均为不可变 let 常量（角色/属性名、遍历阈值、预编译正则），无可变 static 状态、不触主线程独有 API，
/// 故可安全 off-main 调用——把候选触发时阻塞式的 AX 读会话挪到后台线程，腾空主 run loop 让 ESC 回调即时执行。
/// 主线程调 nonisolated 合法，原有 @MainActor 调用方（Inserter/Sticker/Voice/Watcher/控制器）无需改动。
enum WeChatAXProbe {
    // 微信 Mac 可能的 bundle id（不同版本/渠道可能不同）
    static let bundleIDs = ["com.tencent.xinWeChat", "com.tencent.WeChat"]

    // AX role 字面量收敛到共享 AXRole（避免常量类型歧义，跨文件复用）。
    private static let roleStaticText = AXRole.staticText
    private static let roleTextArea = AXRole.textArea
    private static let roleTextField = AXRole.textField
    private static let roleScrollArea = AXRole.scrollArea
    private static let roleSplitGroup = AXRole.splitGroup
    private static let roleTable = AXRole.table
    private static let roleRow = AXRole.row
    private static let roleTableRow = AXRole.tableRow
    private static let roleImage = AXRole.image
    private static let roleColumn = AXRole.column
    private static let roleScrollBar = AXRole.scrollBar

    /// 快速读取只取最后 N 行消息。
    private static let maxMessages = 30

    // MARK: - 遍历护栏阈值（类型级具名常量，取各处现值不调参）

    /// 消息表定位（含 ScrollArea 浅查）的深度上限。
    private static let findMessageTableMaxDepth = 40
    /// 表内首个 AXTable 查找的深度上限。
    private static let findFirstTableMaxDepth = 20
    /// 消息表定位/表查找共用的访问节点数上限（同义阈值合并）。
    private static let tableLookupMaxVisited = 2000
    /// 右侧面板顶部标题收集的深度上限。
    private static let collectTopStaticTextsMaxDepth = 12
    /// 右侧面板顶部标题收集的访问节点数上限。
    private static let collectTopStaticTextsMaxVisited = 400
    /// 行内下钻（图片/文本叶子 frame、首个非空文本）的深度上限（同义阈值合并）。
    private static let rowDescendMaxDepth = 12
    /// 表子树叶子值兜底收集的深度上限。
    private static let collectLeafValuesMaxDepth = 24
    /// 表子树叶子值兜底收集的访问节点数上限。
    private static let collectLeafValuesMaxVisited = 6000
    /// 可编辑元素递归收集的深度上限。
    private static let collectEditablesMaxDepth = 60
    /// composer 宽度门槛，排除左上角窄搜索框。
    private static let minComposerWidth: CGFloat = 120

    enum ProbeError: Error, CustomStringConvertible, Sendable {
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
    enum Speaker: Sendable {
        case me
        case other
        case separator  // 纯时间行 / 系统分隔，正文为时间或提示
    }

    /// 一条消息（探针本地轻量类型，不依赖 ZhiYuCore）。
    struct Message: Sendable {
        let speaker: Speaker
        let name: String   // 发言人名（other 才有意义；me/separator 为空）
        let text: String   // 正文
        /// 图片/表情消息的气泡截图区域（AX 全局左上原点坐标）；普通文本为 nil。
        let imageFrame: CGRect?
        var isMe: Bool { speaker == .me }

        /// 复制并替换 imageFrame（行级填充用：parseMessage 先产出 imageFrame=nil 的副本）。
        func with(imageFrame: CGRect?) -> Message {
            Message(speaker: speaker, name: name, text: text, imageFrame: imageFrame)
        }
    }

    /// 探针读取结果（本地轻量类型，不依赖 ZhiYuCore）。
    struct ProbeResult: Sendable {
        var elapsedMs: Int          // 本次快速读取耗时（毫秒）
        var contactName: String
        var messages: [Message]
        var draft: String
        var inputFrame: CGRect?
        var inputFocused: Bool
        var diagnostics: [String]   // 定位/回退诊断信息
    }

    /// 统一的"这是微信吗"判定（bundle id 命中 bundleIDs，或本地化名为 WeChat/微信）。
    /// findWeChatApp（名字匹配子句）与 CandidatePanelController.isWeChatFrontmost 都调用此函数，口径一致。
    static func isWeChat(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
        return app.localizedName == "WeChat" || app.localizedName == "微信"
    }

    /// 仅按 bundle id 命中 bundleIDs（不含本地化名兜底）。供 findWeChatApp 的「偏向标准包」优先级语义复用。
    private static func isWeChatByID(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(bundleIDs.contains) ?? false
    }

    static func findWeChatApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        // byID 优先：bundle id 命中者优先返回（多实例时偏向标准包）。
        if let byID = apps.first(where: isWeChatByID) {
            return byID
        }
        // 名字匹配复用统一判定 isWeChat（与 CandidatePanelController.isWeChatFrontmost 同口径）。
        return apps.first(where: isWeChat)
    }

    /// 【共享唤醒助手】对 app 元素设置 AXManualAccessibility / AXEnhancedUserInterface。
    /// 这是两个便宜的 set 调用，不做整树遍历。保留以兼容不同版本；失败容错，不 crash。
    @discardableResult
    static func wakeAccessibility(_ appElement: AXUIElement) -> [String] {
        let r1 = AXUIElementSetAttributeValue(appElement, AXAttr.manualAccessibility as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(appElement, AXAttr.enhancedUserInterface as CFString, kCFBooleanTrue)
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
        guard let window = focusedOrMainWindow(of: appElement) else {
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
                contactName: copyString(window, AXAttr.title) ?? app.localizedName ?? "未知联系人",
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
            ?? copyString(window, AXAttr.title)
            ?? app.localizedName
            ?? "未知联系人"

        // d/e. 读消息：遍历消息表的行（文档顺序=时间顺序），只取最后 N 行，读 bestText(AXValue/AXTitle/AXDescription) 并解析说话人。
        var messages: [Message] = []
        if let table = messageTable {
            messages = readMessages(from: table, diagnostics: &diagnostics)
        } else {
            diagnostics.append("未定位到消息列表（结构可能已变）")
        }

        // f. composer：读 AXValue=草稿、frame、AXFocused。
        var draft = ""
        var inputFocused = false
        var inputFrame: CGRect? = nil
        if let c = composer {
            draft = copyString(c, AXAttr.value) ?? ""
            inputFocused = copyBool(c, AXAttr.focused) ?? false
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

    // MARK: - 廉价指纹（高频去重前移，避免每次都跑完整 run()）

    /// 极廉价的会话指纹：只导航到消息表，读"行数 + 最后一行首个非空文本"，
    /// 不解析全部行、不读 frame、不读 composer、不截图。供前台高频 AX 通知在
    /// 昂贵的 run() 之前做去重——指纹不变直接 return，把去重前移到昂贵读取之前。
    /// 读不到（结构未就绪/无权限/无窗口）返回 nil，调用方据此回退到完整 run()。
    static func cheapSignature() -> String? {
        guard AXIsProcessTrusted(), let app = findWeChatApp() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedOrMainWindow(of: appElement) else { return nil }
        var diag: [String] = []
        guard let panel = locateRightPanel(window: window, diagnostics: &diag),
              let table = locateMessageTable(in: panel) else { return nil }
        let rows = rows(of: table)
        guard let lastRow = rows.last else {
            // 拿不到行（个别版本把行挂在 AXColumn 下）：仅用子节点数粗指纹，仍能反映新增。
            return "n\(children(table).count)"
        }
        let lastText = firstNonEmptyValue(in: lastRow, depth: 0) ?? ""
        return "\(rows.count)|\(lastText)"
    }

    /// 极轻量地读取「当前打开会话」的联系人标题：复用 findWeChatApp→focusedOrMainWindow→右侧面板顶部 StaticText
    /// （locateContactTitle/collectTopStaticTexts，只读顶部 StaticText、不下钻消息表/不截图，开销低于 cheapSignature）。
    /// 供落地动作前校验会话身份用。读不到（无权限/无窗口/无右侧面板）返回 nil。
    static func currentContactName() -> String? {
        guard AXIsProcessTrusted(), let app = findWeChatApp() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedOrMainWindow(of: appElement) else { return nil }
        var diag: [String] = []
        guard let panel = locateRightPanel(window: window, diagnostics: &diag) else { return nil }
        return locateContactTitle(in: panel)
    }

    /// 会话身份守卫：当前微信会话是否仍是 target。**默认放行**——target 为 nil / 读不到当前会话 / 当前为空，一律 true（绝不误拦正常发送）；仅在确读到非空且与 target 不同时返回 false。
    static func isCurrentContact(_ target: String?) -> Bool {
        guard let target else { return true }
        guard let cur = currentContactName()?.trimmingCharacters(in: .whitespacesAndNewlines), !cur.isEmpty else { return true }
        return cur == target.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard depth < findMessageTableMaxDepth, visited < tableLookupMaxVisited else { return nil }
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
        guard depth < findFirstTableMaxDepth, visited < tableLookupMaxVisited else { return nil }
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
        guard depth < collectTopStaticTextsMaxDepth, visited < collectTopStaticTextsMaxVisited else { return }
        visited += 1
        let r = role(el)
        // 不下钻 ScrollArea/Table（消息列表、输入区滚动），标题是面板直挂的 AXStaticText。
        if r == roleScrollArea || r == roleTable { return }
        if r == roleStaticText, let s = copyString(el, AXAttr.value),
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
    /// 读 bestText(AXValue/AXTitle/AXDescription)，解析说话人，取最后 N 行。
    private static func readMessages(from table: AXUIElement, diagnostics: inout [String]) -> [Message] {
        let allChildren = children(table)
        let rows = rows(of: table)
        // 行路径：每行取首个非空文本，同时在行子树检测图片/表情的 frame。
        var parsed: [Message] = []
        for row in rows {
            guard let value = firstNonEmptyValue(in: row, depth: 0) else { continue }
            var msg = parseMessage(value)
            // 表情包：行内有 AXImage，取其精确 frame。
            if value.contains(WeChatMarkers.sentSticker) {
                msg = msg.with(imageFrame: findFirstImageFrame(row, depth: 0))
            } else if value.contains(WeChatMarkers.sentImage) {
                // 图片：通常无子 AXImage，截承载该文本的叶子(或整行)的 frame。
                let f = firstNonEmptyValueFrame(in: row, depth: 0) ?? frame(of: row)
                msg = msg.with(imageFrame: f)
            }
            parsed.append(msg)
        }
        var usedFallback = false
        if parsed.isEmpty {
            usedFallback = true
            var rawValues: [String] = []
            var visited = 0
            collectLeafValues(table, depth: 0, visited: &visited, into: &rawValues)
            // 兜底路径拿不到行元素，imageFrame 一律为 nil（仅文本上下文）。
            parsed = rawValues.map { parseMessage($0) }
        }
        diagnostics.append("消息表: 子节点=\(allChildren.count) 行=\(rows.count) 取值=\(parsed.count)\(usedFallback ? "(兜底)" : "")")
        return parsed.count > maxMessages ? Array(parsed.suffix(maxMessages)) : parsed
    }

    /// 在子树中查找第一个 role==AXImage 的节点的 frame（表情包气泡精确区域）。
    private static func findFirstImageFrame(_ el: AXUIElement, depth: Int) -> CGRect? {
        guard depth < rowDescendMaxDepth else { return nil }
        if role(el) == roleImage, let f = frame(of: el) { return f }
        for child in children(el) {
            if let f = findFirstImageFrame(child, depth: depth + 1) { return f }
        }
        return nil
    }

    /// 行内下钻到第一个含非空文本的叶子，返回其 frame（图片消息无子 AXImage 时，截该文本叶子的区域）。
    private static func firstNonEmptyValueFrame(in el: AXUIElement, depth: Int) -> CGRect? {
        guard depth < rowDescendMaxDepth else { return nil }
        if bestText(el) != nil, let f = frame(of: el) { return f }
        for child in children(el) {
            if let f = firstNonEmptyValueFrame(in: child, depth: depth + 1) { return f }
        }
        return nil
    }

    /// 表子树内按文档顺序收集叶子节点的非空 AXValue（跳过 AXColumn/滚动条避免与行重复）。
    private static func collectLeafValues(_ el: AXUIElement, depth: Int, visited: inout Int, into out: inout [String]) {
        guard depth < collectLeafValuesMaxDepth, visited < collectLeafValuesMaxVisited else { return }
        visited += 1
        let r = role(el)
        if r == roleColumn || r == roleScrollBar { return }
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

    /// 行内下钻到第一个含非空文本的叶子，读 bestText(AXValue/AXTitle/AXDescription)。
    private static func firstNonEmptyValue(in el: AXUIElement, depth: Int) -> String? {
        guard depth < rowDescendMaxDepth else { return nil }
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

    /// 预编译正则（固定模式只编译一次，避免每条消息重复 NSRegularExpression 构造）。
    /// 行为不变：模式与原内联字面量逐字一致；DEBUG 下编译失败 assert 暴露，Release 下回退 nil（与原 try? 失败同义）。
    private enum SpeakerRegex {
        /// "^(.+?)说[:：](.*)$"：优先匹配 "X说:" 形式，捕获组 1=name、组 2=body。
        static let saidPattern = "^(.+?)说[:：](.*)$"
        /// "^(.+?)[:：](.*)$"：兜底匹配 "X:" 形式。
        static let colonPattern = "^(.+?)[:：](.*)$"
        /// 纯时间 / 日期分隔行模式。
        static let timeSeparatorPattern = "^(昨天|前天|今天|上午|下午|凌晨|早上|中午|晚上|星期[一二三四五六日天]|周[一二三四五六日天]|[0-9]{1,4}[年/月-]|[\\s])*[0-9]{1,2}[:：][0-9]{2}$"

        static let said = compile(saidPattern, options: [.dotMatchesLineSeparators])
        static let colon = compile(colonPattern, options: [.dotMatchesLineSeparators])
        static let timeSeparator = compile(timeSeparatorPattern, options: [])

        /// 一次性编译；DEBUG 下失败 assert（模式写错能立刻发现），Release 下返回 nil（与原 try? 同义，匹配回退到不命中）。
        private static func compile(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
            do {
                return try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                assertionFailure("预编译正则失败 pattern=\(pattern) error=\(error)")
                return nil
            }
        }
    }

    /// 解析一条消息 value：
    /// - 以 "我说:" 或 "我:" 开头 -> me，正文=分隔符之后。
    /// - 否则匹配 "^(.+?)说[:：]" 或 "^(.+?)[:：]" -> other，name=捕获，正文=分隔符之后。
    /// - 纯时间行 / 空 -> separator。
    /// 冒号兼容半角 : 与全角 ：。
    static func parseMessage(_ raw: String) -> Message {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return Message(speaker: .separator, name: "", text: raw, imageFrame: nil)
        }

        // 纯时间 / 日期分隔行：02:33 / 03:03 / 昨天 20:38 / 上午 9:41 等。
        if isTimeSeparator(value) {
            return Message(speaker: .separator, name: "", text: value, imageFrame: nil)
        }

        // 我说: / 我:（半/全角冒号）
        for prefix in ["我说:", "我说：", "我:", "我："] {
            if value.hasPrefix(prefix) {
                let body = String(value.dropFirst(prefix.count))
                return Message(speaker: .me, name: "", text: body, imageFrame: nil)
            }
        }

        // 对方：^(.+?)说[:：]  优先，其次 ^(.+?)[:：]
        if let (name, body) = matchSpeaker(value, regex: SpeakerRegex.said)
            ?? matchSpeaker(value, regex: SpeakerRegex.colon) {
            return Message(speaker: .other, name: name, text: body, imageFrame: nil)
        }

        // 无分隔符：无法解析说话人，按 other 整条作为正文，name 留空。
        return Message(speaker: .other, name: "", text: value, imageFrame: nil)
    }

    /// 用预编译正则取捕获组 1=name、组 2=body（已 trim）。regex 为 nil（极端：编译失败）时回退不命中。
    private static func matchSpeaker(_ value: String, regex: NSRegularExpression?) -> (name: String, body: String)? {
        guard let regex else { return nil }
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
        guard let regex = SpeakerRegex.timeSeparator else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
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
        for attr in [AXAttr.value, AXAttr.title, AXAttr.description] {
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
        guard AXUIElementCopyAttributeValue(el, AXAttr.children as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    static func role(_ el: AXUIElement) -> String { copyString(el, AXAttr.role) ?? "" }

    /// 读取元素支持的 action 名列表（AXShowMenu/AXPress 等）。供 VoiceTranscriber/StickerSender 复用。
    static func actions(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(el, &arr) == .success, let a = arr as? [String] else { return [] }
        return a
    }

    /// 拿到 app 的前台窗口：AXFocusedWindow 优先，回退 AXMainWindow。各站点统一调用此封装。
    static func focusedOrMainWindow(of app: AXUIElement) -> AXUIElement? {
        copyElement(app, AXAttr.focusedWindow) ?? copyElement(app, AXAttr.mainWindow)
    }

    /// 抽取表的直接行子节点（role==AXRow 或 AXTableRow）。cheapSignature 与 readMessages 复用。
    static func rows(of table: AXUIElement) -> [AXUIElement] {
        children(table).filter {
            let r = role($0)
            return r == roleRow || r == roleTableRow
        }
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        // 仅校验 .success 不够：某些元素/微信版本可能返回 nil 或非 AXValue 包装类型，
        // force-cast 会运行期崩溃。先校验 CFTypeID == AXValueGetTypeID() 再转换。
        guard AXUIElementCopyAttributeValue(el, AXAttr.position as CFString, &posValue) == .success,
              let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(el, AXAttr.size as CFString, &sizeValue) == .success,
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
        guard depth < collectEditablesMaxDepth else { return }
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
}
