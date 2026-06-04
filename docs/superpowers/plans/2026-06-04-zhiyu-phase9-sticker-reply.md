# 知语 Phase 9：表情回复（微信表情搜索自动化）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让知语在生成回复时，模型可选地建议一个"表情关键词"，用户点一下就用微信自带的"表情搜索"找到并发出第一个结果——实现"发原生表情"。

**Architecture:** 不维护本地表情库、不识别用户表情。模型只产出一个中文关键词（合适才给）；App 端用 AX 动作驱动微信表情面板：`AXPress 表情按钮 → 坐标点 🔍 进搜索 → set:Value 写关键词 + AXConfirm → 轮询结果 → AXPress 第一个结果`。除 🔍 一处坐标点击外全用 AX 动作；坐标运行时从 AX 读取，不写死。

**Tech Stack:** Swift 6 / AppKit / ApplicationServices(AX) / CGEvent；ZhiYuCore（Swift Testing TDD）。

**AX 事实依据（已真机 dump 确认，见 .local-notes/sticker-panel-ax.txt）：**
- 表情面板是独立 `AXPopover`（act=Cancel）。
- 主窗口右侧底部工具栏有 `AXButton 「Title=表情」`（act=Press）→ 打开面板。
- 面板默认视图：🔍/😀/❤️/各表情包都是底部一个 `AXScrollArea`（height≈48）里**无标签、无 Press 动作的 AXGroup>AXImage**；**第一个**即 🔍 → 需坐标点击进入搜索。
- 搜索态出现内层 `AXTextField (set:Value, act=ShowMenu,Confirm)`，`PlaceholderValue=搜索表情`。
- 结果格子：`AXStaticText`，`act=Press,ShowMenu,ScrollToVisible`，frame≈72×72，`Title/Description/Help` 含描述。Tab「全部表情/合成表情」与「搜索中」无 Press 且尺寸小，按"有 Press 且 ≥60×60"可干净区分。

---

## Part A — ZhiYuCore（TDD）

### Task 1: 生成结果携带表情关键词（ReplyResult + 解析 + 缓存）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyResult.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/CandidateParser.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Cache/CandidateCache.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyGenerator.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/StickerReplyTests.swift`

- [ ] **Step 1: 写失败测试** `StickerReplyTests.swift`

```swift
import Testing
@testable import ZhiYuCore

@Suite struct StickerReplyTests {
    @Test func parseStickerExtractsKeyword() {
        let raw = "[\"在的\",\"咋了\"]\n表情: 报警"
        #expect(CandidateParser.parseSticker(raw) == "报警")
    }
    @Test func parseStickerFullWidthColonAndQuotes() {
        #expect(CandidateParser.parseSticker("[]\n表情：「笑死」") == "笑死")
    }
    @Test func parseStickerNilWhenAbsent() {
        #expect(CandidateParser.parseSticker("[\"好的\"]") == nil)
    }
    @Test func parseStickerNilWhenNone() {
        #expect(CandidateParser.parseSticker("[\"好的\"]\n表情: 无") == nil)
    }
    @Test func parseCandidatesIgnoresStickerLineInLineFallback() {
        // 非 JSON 兜底路径也不能把"表情:xxx"当候选
        let raw = "好的\n在的\n表情: 报警"
        let items = CandidateParser.parse(raw, max: 5)
        #expect(items == ["好的", "在的"])
    }
    @Test func generateReturnsResultWithSticker() async throws {
        let provider = StubProvider(raw: "[\"哈哈\",\"笑死\"]\n表情: 笑死")
        let cache = CandidateCache()
        let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 2, modelTag: "t")
        let ctx = ChatContext(contactName: "x", messages: [ChatMessage(speaker: .other, text: "你看这个")], draft: "")
        let r = try await gen.generate(context: ctx, style: .casual)
        #expect(r.candidates == ["哈哈", "笑死"])
        #expect(r.stickerKeyword == "笑死")
        // 缓存命中也应保留关键词
        let r2 = try await gen.generate(context: ctx, style: .casual)
        #expect(r2.stickerKeyword == "笑死")
    }
}

private struct StubProvider: LLMProvider {
    let raw: String
    func complete(messages: [LLMMessage]) async throws -> String { raw }
}
```

> 注意：若 `ChatContext`/`ChatMessage`/`ReplyStyle.casual`/`LLMProvider` 的初始化签名与上面不符，按仓库现有定义调整测试构造（保持断言不变）。`ReplyStyle` 取一个已存在的实例（如 `.casual`/`.friendly`，以源码为准）。

- [ ] **Step 2: 跑测试确认失败（编译失败：ReplyResult/parseSticker 未定义）**

Run: `cd ZhiYuCore && swift test --filter StickerReplyTests`
Expected: 编译失败 / 断言失败。

- [ ] **Step 3: 实现 ReplyResult**

`ReplyResult.swift`:
```swift
import Foundation

/// 一次生成的结果：文字候选 + 可选的"表情关键词"（模型觉得适合配表情时给）。
public struct ReplyResult: Sendable, Equatable {
    public let candidates: [String]
    public let stickerKeyword: String?
    public init(candidates: [String], stickerKeyword: String?) {
        self.candidates = candidates
        self.stickerKeyword = stickerKeyword
    }
}
```

- [ ] **Step 4: CandidateParser 加 parseSticker，并让兜底解析忽略表情行**

在 `CandidateParser` 中新增：
```swift
    /// 解析可选的"表情关键词"：匹配独立的一行 `表情: 关键词` / `表情：关键词`（半/全角冒号）。
    /// 去掉引号/方括号/书名号；"无"/"none"/"没有"视为不建议表情，返回 nil。
    public static func parseSticker(_ raw: String) -> String? {
        guard let r = raw.range(of: "(?m)^\\s*表情\\s*[:：]\\s*(.+)$", options: .regularExpression) else {
            return nil
        }
        var s = String(raw[r])
        if let colon = s.range(of: "[:：]", options: .regularExpression) {
            s = String(s[colon.upperBound...])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'「」『』【】[]()（）"))
        let lowered = s.lowercased()
        if s.isEmpty || ["无", "没有", "none", "n/a", "不需要"].contains(lowered) { return nil }
        return s
    }
```
并在 `parseLines` 的结果里剔除表情行：把 `parseLines` 改为在 split 后 `filter { line in !line.contains("表情:") && !line.contains("表情：") }`（或在返回前过滤匹配 `^\s*表情\s*[:：]` 的项）。最稳妥：在 `parse(_:max:)` 内，对 `parseLines` 的产物追加 `.filter { $0.range(of: "^\\s*表情\\s*[:：]", options: .regularExpression) == nil }`。

- [ ] **Step 5: CandidateCache 加表情关键词存取（不破坏既有 [String] API）**

在 `CandidateCache` 中新增并发安全的并行存储：
```swift
    private var stickerStorage: [String: String] = [:]

    public func stickerKeyword(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stickerStorage[key]
    }

    public func storeSticker(_ keyword: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let k = keyword, !k.isEmpty { stickerStorage[key] = k } else { stickerStorage[key] = nil }
    }
```
并在 `clear()` 里追加 `stickerStorage.removeAll()`。

- [ ] **Step 6: ReplyGenerator 返回 ReplyResult**

把 `generate` 改为返回 `ReplyResult`：
```swift
    public func generate(context: ChatContext, style: ReplyStyle) async throws -> ReplyResult {
        let key = ContextHasher.key(for: context)
            + "|style:" + style.name
            + "|n:\(candidateCount)"
            + "|instr:" + style.instruction
            + "|model:" + modelTag
        if let cached = cache.candidates(forKey: key) {
            return ReplyResult(candidates: cached, stickerKeyword: cache.stickerKeyword(forKey: key))
        }
        let messages = PromptBuilder.build(context: context, style: style, candidateCount: candidateCount)
        let raw = try await provider.complete(messages: messages)
        let candidates = CandidateParser.parse(raw, max: candidateCount)
        let sticker = CandidateParser.parseSticker(raw)
        cache.store(candidates, forKey: key)
        cache.storeSticker(sticker, forKey: key)
        return ReplyResult(candidates: candidates, stickerKeyword: sticker)
    }
```

- [ ] **Step 7: PromptBuilder 增加"可选表情建议"指令**

在 system 文案末尾追加（紧接现有"不要任何额外解释或编号..."之后）：
```
此外：若此刻用一个表情包回应会更自然，可在 JSON 数组之后【另起一行】写「表情: 关键词」（关键词用中文、1-4 字，会用于在微信表情里搜索，如 报警、笑死、无语、好的、爱你、晚安）。多数情况普通文字即可，不必每次都给；不合适就不要这一行，也不要把它写进 JSON 数组里。
```

- [ ] **Step 8: 跑测试确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含既有 59 测试 + 新增）。

- [ ] **Step 9: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): 生成结果携带可选表情关键词（ReplyResult+解析+缓存+prompt）"
```

---

## Part B — App（截图自动化，构建验证 + 真机联调）

### Task 2: StickerSender（驱动微信表情搜索发送）

**Files:**
- Create: `ZhiYu/WeChat/StickerSender.swift`

- [ ] **Step 1: 实现 StickerSender**（复用 `WeChatAXProbe` 的 internal 辅助）

```swift
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
            .min(by: { (WeChatAXProbe.frame(of: $0)!.minX, WeChatAXProbe.frame(of: $0)!.minY)
                       < (WeChatAXProbe.frame(of: $1)!.minX, WeChatAXProbe.frame(of: $1)!.minY) })
    }

    private static func firstResultCell(in popover: AXUIElement) -> AXUIElement? {
        var cells: [AXUIElement] = []
        collectMatching(in: popover, into: &cells) { el in
            guard WeChatAXProbe.role(el) == "AXStaticText",
                  let f = WeChatAXProbe.frame(of: el), f.width >= 60, f.height >= 60 else { return false }
            return actions(el).contains("AXPress")
        }
        return cells.min(by: {
            let a = WeChatAXProbe.frame(of: $0)!, b = WeChatAXProbe.frame(of: $1)!
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
```

- [ ] **Step 2: 构建**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（修正任何 API 偏差）。

### Task 3: 候选面板接入表情芯片

**Files:**
- Modify: `ZhiYu/Panel/CandidatePanelView.swift`
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`

- [ ] **Step 1: Model 增加字段/回调**（CandidatePanelView.swift 内 `CandidatePanelModel`）

```swift
    @Published var stickerKeyword: String? = nil
    var onSendSticker: (String) -> Void = { _ in }
```

- [ ] **Step 2: View 增加表情芯片**（放在 `content` 的候选列表之后，或 footer 之上）

在 `body` 的 `VStack` 中、`content` 之后插入：
```swift
            stickerSuggestion
```
并新增：
```swift
    @ViewBuilder private var stickerSuggestion: some View {
        if let kw = model.stickerKeyword, !kw.isEmpty {
            Button { model.onSendSticker(kw) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("发表情：\(kw)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("用微信表情搜索发出第一个结果")
        }
    }
```
> 注意：表情芯片在 `model.isLoading == false` 时才有意义；`stickerKeyword` 为 nil 时该视图为空，天然不显示。即使 candidates 为空但有 keyword 也应显示芯片。

- [ ] **Step 2.5:** 确认空态判断不误伤：`content` 里 `model.candidates.isEmpty` 显示"没有候选"——当 candidates 为空但 stickerKeyword 非空时仍应让芯片可见（芯片在 content 之外，已满足）。无需改 content。

- [ ] **Step 3: Controller 接线**（CandidatePanelController.swift）

`trigger()` 内把：
```swift
                let result = try await gen.generate(context: context, style: style)
                self.model.candidates = result
                self.model.isLoading = false
                if result.isEmpty { self.model.status = "模型没有返回候选" }
```
改为：
```swift
                let result = try await gen.generate(context: context, style: style)
                self.model.candidates = result.candidates
                self.model.stickerKeyword = result.stickerKeyword
                self.model.isLoading = false
                if result.candidates.isEmpty && result.stickerKeyword == nil { self.model.status = "模型没有返回候选" }
```
`showPanel(...)` 里，与现有 onFill/onSend 并列，新增：
```swift
        model.onSendSticker = { [weak self] kw in self?.dismiss(); StickerSender.send(keyword: kw) }
```
并在 `trigger()` 起始重置 `model.stickerKeyword = nil`（与 `model.candidates = []` 同处）。

- [ ] **Step 4: 构建**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 表情回复——候选面板表情芯片 + StickerSender 驱动微信表情搜索发送"
```

### Task 4: 真机联调（人工，不在本计划自动执行）

授权辅助功能（已有）→ 在「文件传输助手」对话 → 双击右⌘ → 出现"发表情：xxx"芯片 → 点击 → 观察：
1. 表情面板是否被程序打开；
2. 坐标点 🔍 是否进入搜索（**最脆点**，不行则调整 `bottomToolbarFirstItem` 选择逻辑）；
3. 关键词是否写入并触发搜索；
4. 是否 AXPress 了第一个结果并**直接发出**（若只填入未发出，需追加发送动作）。

---

## Self-Review
- Spec 覆盖：模型可选关键词（Task1 prompt/parse）、缓存一致（Task1 cache）、UI 芯片（Task3）、自动化发送（Task2）、联调（Task4）。✅
- 类型一致：`ReplyResult{candidates,stickerKeyword}` 在 generate/controller/view 三处一致；`generate` 返回类型变更已在 controller 同步。✅
- 无占位符：StickerSender / parseSticker / cache / prompt 均给出完整代码。✅
- 风险：① 🔍 坐标点击（已给 AXPress 优先 + 坐标兜底 + 失败 beep）；② "点结果是否直接发"留待联调；③ result 排序用 (minY,minX) 取左上第一个。
