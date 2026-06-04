# 知语 ZhiYu — Phase 7：多条短消息回复（拟合对方节奏） 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当对方连发多条短消息时，让回复也用相近数量的简短消息回应，且**每条单独发出**（而非挤进一条长消息）。

**Architecture:** 模型产出"多气泡"候选——每条候选内部用换行 `\n` 分隔多条小消息；prompt 里带"对方末尾连发条数"提示让模型拟合数量/长度。发送时把候选按换行拆开逐条单独发出。纯逻辑（连发计数、气泡拆分、prompt 改造）放 `ZhiYuCore`(TDD)；发送/展示放 App。

**Tech Stack:** Swift 6.3 / SwiftUI / Swift Testing。分支 **main**。

**前置：** Phase 1-6 完成。已有 `PromptBuilder.build(context:style:candidateCount:)`、`ChatMessage(speaker:.me/.other)`、`Inserter.fill/fillAndSend`、`CandidatePanelController`、`CandidatePanelView`。候选当前是 `[String]`（N 条，每条单消息）。本期不改候选类型，仅约定"候选字符串内换行=多气泡"。

---

## Task 1：ZhiYuCore——连发计数 + 气泡拆分

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/MessageRhythm.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/BubbleSplitter.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/MultiBubbleTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/MultiBubbleTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func trailingOtherCountCountsConsecutiveTailOther() {
    let m: [ChatMessage] = [
        .init(speaker: .me, text: "在"),
        .init(speaker: .other, text: "a"),
        .init(speaker: .other, text: "b"),
        .init(speaker: .other, text: "c"),
    ]
    #expect(MessageRhythm.trailingOtherCount(m) == 3)
}

@Test func trailingOtherCountZeroWhenLastIsMe() {
    let m: [ChatMessage] = [.init(speaker: .other, text: "a"), .init(speaker: .me, text: "在")]
    #expect(MessageRhythm.trailingOtherCount(m) == 0)
    #expect(MessageRhythm.trailingOtherCount([]) == 0)
}

@Test func bubbleSplitterSplitsOnNewlinesTrimmedNonEmpty() {
    #expect(BubbleSplitter.split("在的\n咋了\n哈哈") == ["在的", "咋了", "哈哈"])
    #expect(BubbleSplitter.split("  好的  ") == ["好的"])
    #expect(BubbleSplitter.split("a\n\n  b ") == ["a", "b"])
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter MultiBubbleTests`
Expected: 编译失败（`MessageRhythm`/`BubbleSplitter` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/MessageRhythm.swift`:
```swift
import Foundation

public enum MessageRhythm {
    /// 末尾连续"对方"消息的条数（对方最近连发了几条）。
    public static func trailingOtherCount(_ messages: [ChatMessage]) -> Int {
        var n = 0
        for m in messages.reversed() {
            if m.speaker == .other { n += 1 } else { break }
        }
        return n
    }
}
```

`ZhiYuCore/Sources/ZhiYuCore/Generation/BubbleSplitter.swift`:
```swift
import Foundation

public enum BubbleSplitter {
    /// 把一条候选（可能含换行）拆成多条气泡：按换行分、trim、去空。全空时退回整段(已 trim)。
    public static func split(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter MultiBubbleTests`
Expected: 3 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): MessageRhythm 连发计数 + BubbleSplitter 气泡拆分" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：PromptBuilder——多气泡 + 拟合对方节奏

**Files:**
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`
- Modify: `ZhiYuCore/Tests/ZhiYuCoreTests/PromptBuilderTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `ZhiYuCore/Tests/ZhiYuCoreTests/PromptBuilderTests.swift` 末尾追加（`sampleContext` 已在文件内，末条为对方且 trailing=1）：
```swift
@Test func systemMentionsMultiBubbleWhenOtherSentSeveral() {
    let ctx = ChatContext(
        contactName: "张婷",
        messages: [
            ChatMessage(speaker: .me, text: "在"),
            ChatMessage(speaker: .other, text: "在吗"),
            ChatMessage(speaker: .other, text: "出来玩不"),
            ChatMessage(speaker: .other, text: "就现在"),
        ],
        draft: "")
    let sys = PromptBuilder.build(context: ctx, style: .concise, candidateCount: 3).first?.content ?? ""
    #expect(sys.contains("连发"))      // 提到对方连发
    #expect(sys.contains("3"))         // 连发条数(也=候选数，均为3)
    #expect(sys.contains("换行"))      // 多气泡用换行分隔
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter PromptBuilderTests`
Expected: 新测试 FAIL（system 未含"连发/换行"）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`（整文件替换）:
```swift
import Foundation

/// 把对话上下文 + 风格 + 候选数量组装成发给模型的消息。
/// 支持"多气泡"：对方连发多条时，回复也用相近数量的简短消息，每条候选内部用换行分隔。
public enum PromptBuilder {
    public static func build(context: ChatContext, style: ReplyStyle, candidateCount: Int) -> [LLMMessage] {
        let trailing = MessageRhythm.trailingOtherCount(context.messages)
        let rhythm: String
        if trailing >= 2 {
            rhythm = "对方最近连发了 \(trailing) 条消息。请用相近数量（约 \(trailing) 条）的简短消息回应，"
                + "模仿对方的长度与节奏，不要把多句挤成一长段；"
                + "每条候选内部用换行符 \\n 分隔这些小消息（发送时会拆成多条单独发出）。"
        } else {
            rhythm = "对方最近只发了一条，正常回一条即可（不需要换行拆分）。"
        }
        let system = """
        你在帮"我"快速回复微信聊天。请基于下面的对话，站在"我"的角度生成 \(candidateCount) 条候选回复。
        风格要求：\(style.instruction)
        \(rhythm)
        必须用对话所用语言回复（对方用中文就用中文）。回复要像真人微信聊天，自然、简短。
        只返回一个 JSON 数组，含 \(candidateCount) 条候选；每条是一个字符串（多条小消息用 \\n 分隔）。
        不要任何额外解释或编号。例如：["在的\\n咋了","哈哈笑死\\n你太逗了\\n等我会儿"]
        """
        var convo = "对话（按时间顺序）：\n"
        for m in context.messages {
            let who = m.speaker == .me ? "我" : "对方"
            convo += "\(who): \(m.text)\n"
        }
        if !context.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            convo += "\n我已经打了草稿：「\(context.draft)」。请在此基础上续写/润色，生成候选。\n"
        }
        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: convo),
        ]
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含新测试；原有 PromptBuilder 测试仍通过——风格/候选数/语言/草稿断言不变）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): PromptBuilder 支持多气泡回复，拟合对方连发节奏" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：Inserter 逐条发送 + 控制器拆气泡

**Files:**
- Modify: `ZhiYu/WeChat/Inserter.swift`
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`

- [ ] **Step 1: Inserter 加 sendSequential**

在 `ZhiYu/WeChat/Inserter.swift` 的 `enum Inserter` 内追加：
```swift
    /// 把多条气泡逐条单独发出（每条之间留间隔，给微信处理时间）。
    static func sendSequential(_ parts: [String]) {
        sendNext(parts, 0)
    }

    private static func sendNext(_ parts: [String], _ i: Int) {
        guard i < parts.count else { return }
        let text = parts[i]
        guard !text.isEmpty else { sendNext(parts, i + 1); return }
        fillAndSend(text) { _ in
            // 上一条发出后留 0.4s 再发下一条（叠加 fillAndSend 内部时序，约 0.8s/条）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sendNext(parts, i + 1)
            }
        }
    }
```

- [ ] **Step 2: 控制器 onSend 拆气泡逐条发，onFill 填整段**

在 `ZhiYu/Panel/CandidatePanelController.swift` 的 `showPanel(...)` 里，把 onSend 改为按气泡拆分逐条发：
```swift
        model.onSend = { [weak self] t in
            Inserter.sendSequential(BubbleSplitter.split(t))
            self?.dismiss()
        }
```
`onFill` 保持填整段（含换行供编辑）：
```swift
        model.onFill = { [weak self] t in Inserter.fill(t); self?.dismiss() }
```
（文件已 `import ZhiYuCore`，可直接用 `BubbleSplitter`。）

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 发送时按气泡拆分逐条单独发出" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：候选卡多气泡展示

**Files:**
- Modify: `ZhiYu/Panel/CandidatePanelView.swift`

- [ ] **Step 1: 候选正文改为按气泡分行展示**

把 `CandidatePanelView` 的 `card(index:text:)` 里渲染候选正文的那段（当前是单个 `Text(c)...onTapGesture{...}`）替换为：把候选用 `BubbleSplitter.split(c)` 拆开；单条时仍显示一个 `Text`，多条时纵向显示每条小气泡。整块仍可点击=填入。

在 `CandidatePanelView.swift` 顶部确保 `import ZhiYuCore`（用 BubbleSplitter）。把原来的：
```swift
            Text(c)
                .font(.body)
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { model.onFill(c) }
```
替换为：
```swift
            VStack(alignment: .leading, spacing: 5) {
                let bubbles = BubbleSplitter.split(c)
                if bubbles.count > 1 {
                    ForEach(Array(bubbles.enumerated()), id: \.offset) { _, b in
                        Text(b)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.white.opacity(0.06)))
                    }
                } else {
                    Text(c)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.onFill(c) }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 候选卡按气泡分行展示多条短消息" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：手动验收

- [ ] **Step 1: 多气泡生成**
找一个对方**连发了 3-4 条**短消息的会话 → 双击右⌘ → 候选里应出现**分成多条小气泡**的候选（数量与对方相近）。

- [ ] **Step 2: 逐条发送**
点某条候选的"发送" → 应在"文件传输助手"看到**多条单独的消息**依次发出（不是一条长消息）。

- [ ] **Step 3: 单条场景不回归**
对方只发了一条时 → 候选仍是正常单条，发送=一条消息。

> 想调：每条间隔时长、气泡视觉、是否要个"强制单条/多条"开关，直接说。

## 自检 / Roadmap
- 自检：ZhiYuCore swift test 全绿；App BUILD SUCCEEDED。
- 后续：可选聚焦自动触发、按联系人风格、流式候选、打包分发。
