# 知语 ZhiYu — Phase 2：端到端候选生成 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通第一条竖切闭环——读取微信当前对话(WeChatReader) → 去重(ContextHasher/CandidateCache) → 组装 prompt(PromptBuilder) → 调 OpenAI(OpenAICompatibleProvider, API Key) → 解析出 N 条候选(CandidateParser)，在探针窗口里点一下显示候选，并能"填入/发送"。

**Architecture:** 纯逻辑（Provider 抽象、prompt 组装、候选解析、生成编排）放进 `ZhiYuCore` 包用 `swift test` 做 TDD（网络用 URLProtocol mock）；系统集成（AX 读取适配为 `ChatContext`、Keychain、插入/发送、生成 UI）放在 App，用 `xcodebuild` 编译验证 + 真 OpenAI Key 手动联调。Provider 不碰 Keychain（保持纯净可测）——App 从 Keychain 取 key 传入。

**Tech Stack:** Swift 6.3 / SwiftUI / AppKit / ApplicationServices(AX) / Security(Keychain) / URLSession / Swift Package Manager + Swift Testing。目标 macOS 26.5。

**对应 spec:** `docs/superpowers/specs/2026-06-04-zhiyu-wechat-reply-assistant-design.md`
**探针结论:** `docs/superpowers/notes/2026-06-04-probe-findings.md`（AX 读/写/发送已实证，含 bestText/说话人/发送条件等关键细节）

**前置状态:** Phase 1 已完成，在分支 `phase1-skeleton-and-probe`。`ZhiYuCore` 已有 `ChatMessage`/`ChatContext`/`ContextHasher`/`CandidateCache`。探针 `WeChatAXProbe`(快速读取)、`InserterProbe`(写入+激活聚焦+回车/粘贴) 均已验证可用。**本计划在同一分支继续。**

---

## 文件结构

### `ZhiYuCore/`（纯逻辑，`swift test` TDD）
```
Sources/ZhiYuCore/
  Provider/
    LLMMessage.swift          # {role: system/user/assistant, content}
    ProviderConfig.swift      # {name, baseURL, model}，含 OpenAI 预设
    ProviderError.swift       # 错误枚举
    LLMProvider.swift         # protocol: complete(messages) async throws -> String
    OpenAICompatibleProvider.swift  # OpenAI /chat/completions 请求与解析（URLSession 可注入）
  Generation/
    ReplyStyle.swift          # 预设风格 + 自定义
    PromptBuilder.swift       # ChatContext + 风格 + N -> [LLMMessage]
    CandidateParser.swift     # 模型原文 -> [候选]（JSON 数组优先，行号兜底）
    ReplyGenerator.swift      # 编排：hash→缓存→provider→解析→存缓存
Tests/ZhiYuCoreTests/
    OpenAIProviderTests.swift / PromptBuilderTests.swift /
    CandidateParserTests.swift / ReplyGeneratorTests.swift / ReplyStyleTests.swift
```

### `ZhiYu/`（App，`xcodebuild` + 手动联调）
```
ZhiYu/
  WeChat/
    WeChatReader.swift        # 适配器：调探针读取逻辑 -> ZhiYuCore.ChatContext
    Inserter.swift            # fill / fillAndSend，包装已验证的 InserterProbe 路径
  Secrets/
    KeychainStore.swift       # 存/取 OpenAI API Key
  Generate/
    GeneratePanel.swift       # 探针窗口内的生成区：Key/模型/风格输入 + 生成 + 候选卡(填入/发送)
  Probe/ProbeView.swift       # 修改：嵌入 GeneratePanel
```

---

## 一次性手动步骤（仅 Task 7 需要）
把 `ZhiYuCore` 通过 Xcode GUI 加为 App 的本地包依赖（objectVersion 77 手改 pbxproj 风险高，GUI 最稳）。其余任务均可命令行验证。

---

## Task 1：Provider 基础类型（LLMMessage / ProviderConfig / ProviderError）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Provider/LLMMessage.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Provider/ProviderConfig.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Provider/ProviderError.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ProviderTypesTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ProviderTypesTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func openAIPresetHasExpectedBaseURL() {
    let c = ProviderConfig.openAI(model: "gpt-4o")
    #expect(c.name == "OpenAI")
    #expect(c.baseURL == "https://api.openai.com/v1")
    #expect(c.model == "gpt-4o")
}

@Test func llmMessageRoleRawValues() {
    #expect(LLMMessage.Role.system.rawValue == "system")
    #expect(LLMMessage.Role.user.rawValue == "user")
    #expect(LLMMessage.Role.assistant.rawValue == "assistant")
    let m = LLMMessage(role: .user, content: "hi")
    #expect(m.content == "hi")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ProviderTypesTests`
Expected: 编译失败（类型未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Provider/LLMMessage.swift`:
```swift
import Foundation

/// 发给大模型的一条对话消息。
public struct LLMMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
```

`ZhiYuCore/Sources/ZhiYuCore/Provider/ProviderConfig.swift`:
```swift
import Foundation

/// 一个大模型 Provider 的连接配置。Phase 2 仅用 API Key 鉴权（key 不放这里，调用时传入）。
public struct ProviderConfig: Equatable, Sendable {
    public let name: String
    public let baseURL: String   // 形如 "https://api.openai.com/v1"
    public let model: String
    public init(name: String, baseURL: String, model: String) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }
    public static func openAI(model: String) -> ProviderConfig {
        ProviderConfig(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: model)
    }
}
```

`ZhiYuCore/Sources/ZhiYuCore/Provider/ProviderError.swift`:
```swift
import Foundation

public enum ProviderError: Error, Equatable, Sendable {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case invalidResponse
    case network(String)
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter ProviderTypesTests`
Expected: 2 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): Provider 基础类型 LLMMessage/ProviderConfig/ProviderError" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：LLMProvider 协议 + OpenAICompatibleProvider（URLProtocol mock TDD）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Provider/LLMProvider.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Provider/OpenAICompatibleProvider.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/OpenAIProviderTests.swift`

- [ ] **Step 1: 写失败测试（含 Mock URLProtocol）**

`ZhiYuCore/Tests/ZhiYuCoreTests/OpenAIProviderTests.swift`:
```swift
import Testing
import Foundation
@testable import ZhiYuCore

/// 拦截网络请求的 mock（测试用）。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: cfg)
}

@Test func completeSendsBearerAndModelAndParsesContent() async throws {
    var captured: URLRequest?
    MockURLProtocol.handler = { req in
        captured = req
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"你好呀"}}]}
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, body)
    }
    let provider = OpenAICompatibleProvider(
        config: .openAI(model: "gpt-4o"), apiKey: "sk-test", session: mockSession())
    let text = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
    #expect(text == "你好呀")
    #expect(captured?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
}

@Test func completeThrowsOnHTTPError() async {
    MockURLProtocol.handler = { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (resp, Data("unauthorized".utf8))
    }
    let provider = OpenAICompatibleProvider(
        config: .openAI(model: "gpt-4o"), apiKey: "bad", session: mockSession())
    await #expect(throws: ProviderError.self) {
        _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
    }
}

@Test func completeThrowsMissingAPIKey() async {
    let provider = OpenAICompatibleProvider(
        config: .openAI(model: "gpt-4o"), apiKey: "", session: mockSession())
    await #expect(throws: ProviderError.missingAPIKey) {
        _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter OpenAIProviderTests`
Expected: 编译失败（`LLMProvider`/`OpenAICompatibleProvider` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Provider/LLMProvider.swift`:
```swift
import Foundation

/// 大模型 Provider 抽象：给定一组消息，返回助手的原始回复文本。
public protocol LLMProvider: Sendable {
    func complete(messages: [LLMMessage]) async throws -> String
}
```

`ZhiYuCore/Sources/ZhiYuCore/Provider/OpenAICompatibleProvider.swift`:
```swift
import Foundation

/// 调用 OpenAI 兼容的 /chat/completions。Key 由调用方传入（不读 Keychain，保持可测）。
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [LLMMessage]
        let temperature: Double
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, messages: messages, temperature: 0.8))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpError(status: http.statusCode,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ProviderError.invalidResponse
        }
        return content
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter OpenAIProviderTests`
Expected: 3 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): OpenAI 兼容 Provider（请求/解析/错误，URLProtocol mock 测试）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：回复风格 ReplyStyle

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyStyle.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ReplyStyleTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ReplyStyleTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func presetsContainConciseAndAreNonEmpty() {
    #expect(ReplyStyle.presets.count == 5)
    #expect(ReplyStyle.presets.contains { $0.name == "简洁" })
    #expect(ReplyStyle.presets.allSatisfy { !$0.instruction.isEmpty })
}

@Test func customStyleCarriesInstruction() {
    let s = ReplyStyle.custom("像东北老铁那样说话")
    #expect(s.name == "自定义")
    #expect(s.instruction == "像东北老铁那样说话")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ReplyStyleTests`
Expected: 编译失败（`ReplyStyle` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyStyle.swift`:
```swift
import Foundation

/// 回复风格：预设或自定义。instruction 会拼进 system prompt。
public struct ReplyStyle: Equatable, Sendable {
    public let name: String
    public let instruction: String
    public init(name: String, instruction: String) {
        self.name = name
        self.instruction = instruction
    }
    public static let concise  = ReplyStyle(name: "简洁", instruction: "回复简洁、口语化，通常不超过两句。")
    public static let friendly = ReplyStyle(name: "友好", instruction: "语气友好亲切、自然随和。")
    public static let formal   = ReplyStyle(name: "正式", instruction: "语气得体、礼貌、稳重。")
    public static let humorous = ReplyStyle(name: "幽默", instruction: "适度幽默、轻松，但不油腻。")
    public static let warm     = ReplyStyle(name: "热情", instruction: "热情、有温度、让人舒服。")
    public static let presets: [ReplyStyle] = [.concise, .friendly, .formal, .humorous, .warm]
    public static func custom(_ instruction: String) -> ReplyStyle {
        ReplyStyle(name: "自定义", instruction: instruction)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter ReplyStyleTests`
Expected: 2 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): 回复风格 ReplyStyle（预设+自定义）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：PromptBuilder（ChatContext + 风格 + N -> 消息）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/PromptBuilderTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/PromptBuilderTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

private func sampleContext(draft: String = "") -> ChatContext {
    ChatContext(
        contactName: "张婷",
        messages: [
            ChatMessage(speaker: .other, text: "你咋不看我给你发的抖音"),
            ChatMessage(speaker: .me, text: "我好像感冒了"),
            ChatMessage(speaker: .other, text: "那你早点睡"),
        ],
        draft: draft)
}

@Test func systemMessageContainsStyleAndCountAndLanguageRule() {
    let msgs = PromptBuilder.build(context: sampleContext(), style: .humorous, candidateCount: 3)
    #expect(msgs.first?.role == .system)
    let sys = msgs.first?.content ?? ""
    #expect(sys.contains("适度幽默"))      // 风格 instruction
    #expect(sys.contains("3"))             // 候选数量
    #expect(sys.contains("对话所用语言"))   // 语言规则
}

@Test func userMessageRendersConversationWithSpeakers() {
    let msgs = PromptBuilder.build(context: sampleContext(), style: .concise, candidateCount: 3)
    let user = msgs.last?.content ?? ""
    #expect(msgs.last?.role == .user)
    #expect(user.contains("对方: 你咋不看我给你发的抖音"))
    #expect(user.contains("我: 我好像感冒了"))
}

@Test func draftIsIncludedWhenPresent() {
    let withDraft = PromptBuilder.build(context: sampleContext(draft: "我在想"), style: .concise, candidateCount: 3)
    #expect((withDraft.last?.content ?? "").contains("我在想"))
    let without = PromptBuilder.build(context: sampleContext(draft: ""), style: .concise, candidateCount: 3)
    #expect(!(without.last?.content ?? "").contains("草稿"))
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter PromptBuilderTests`
Expected: 编译失败（`PromptBuilder` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`:
```swift
import Foundation

/// 把对话上下文 + 风格 + 候选数量组装成发给模型的消息。
public enum PromptBuilder {
    public static func build(context: ChatContext, style: ReplyStyle, candidateCount: Int) -> [LLMMessage] {
        let system = """
        你在帮"我"快速回复微信聊天。请基于下面的对话，站在"我"的角度生成 \(candidateCount) 条候选回复。
        风格要求：\(style.instruction)
        必须用对话所用语言回复（对方用中文就用中文）。回复要像真人微信聊天，自然、简短。
        只返回一个 JSON 数组，元素是 \(candidateCount) 条候选回复字符串，不要任何额外解释或编号。
        例如：["好的","稍等我看看","马上到"]
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

Run: `cd ZhiYuCore && swift test --filter PromptBuilderTests`
Expected: 3 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): PromptBuilder 组装风格/上下文/草稿/候选数量" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：CandidateParser（模型原文 -> 候选数组）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/CandidateParser.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/CandidateParserTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/CandidateParserTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func parsesJSONArray() {
    let raw = "[\"好的\",\"稍等\",\"马上到\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["好的", "稍等", "马上到"])
}

@Test func parsesJSONArrayWrappedInText() {
    let raw = "当然可以：\n[\"嗯嗯\", \"在的\"]\n希望有用"
    #expect(CandidateParser.parse(raw, max: 3) == ["嗯嗯", "在的"])
}

@Test func fallbackParsesNumberedLines() {
    let raw = "1. 好的\n2、稍等\n3) 马上到"
    #expect(CandidateParser.parse(raw, max: 3) == ["好的", "稍等", "马上到"])
}

@Test func capsToMaxAndTrimsAndDedups() {
    let raw = "[\"a\",\"a\",\"  b  \",\"c\",\"d\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["a", "b", "c"])
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter CandidateParserTests`
Expected: 编译失败（`CandidateParser` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/CandidateParser.swift`:
```swift
import Foundation

/// 把模型原始输出解析为候选列表：优先 JSON 字符串数组，失败则按行兜底（去编号/项目符号）。
public enum CandidateParser {
    public static func parse(_ raw: String, max: Int) -> [String] {
        var items = parseJSONArray(raw) ?? parseLines(raw)
        // trim + 去空 + 去重（保序）
        var seen = Set<String>()
        items = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        return Array(items.prefix(max))
    }

    /// 截取第一个 [ ... ] 区间按 JSON 字符串数组解析。
    private static func parseJSONArray(_ raw: String) -> [String]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            return nil
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr
    }

    /// 兜底：按行拆，去掉前导编号/项目符号/引号。
    private static func parseLines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline).map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            // 去前导 "1." / "2、" / "3)" / "-" / "•"
            if let r = s.range(of: "^\\s*([0-9]+[.、)]|[-•])\\s*", options: .regularExpression) {
                s.removeSubrange(r)
            }
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter CandidateParserTests`
Expected: 4 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): CandidateParser（JSON 数组优先，行号兜底，去重截断）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6：ReplyGenerator（编排：hash→缓存→provider→解析→缓存）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyGenerator.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ReplyGeneratorTests.swift`

- [ ] **Step 1: 写失败测试（含 Mock Provider）**

`ZhiYuCore/Tests/ZhiYuCoreTests/ReplyGeneratorTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

/// 记录调用次数的假 provider。
final class CountingProvider: LLMProvider, @unchecked Sendable {
    private(set) var calls = 0
    let canned: String
    init(canned: String) { self.canned = canned }
    func complete(messages: [LLMMessage]) async throws -> String {
        calls += 1
        return canned
    }
}

private func ctx() -> ChatContext {
    ChatContext(contactName: "张婷",
                messages: [ChatMessage(speaker: .other, text: "在吗")],
                draft: "")
}

@Test func generatesParsedCandidates() async throws {
    let provider = CountingProvider(canned: "[\"在\",\"在的\",\"怎么了\"]")
    let gen = ReplyGenerator(provider: provider, cache: CandidateCache(), candidateCount: 3)
    let result = try await gen.generate(context: ctx(), style: .concise)
    #expect(result == ["在", "在的", "怎么了"])
    #expect(provider.calls == 1)
}

@Test func sameContextAndStyleHitsCacheNoSecondCall() async throws {
    let provider = CountingProvider(canned: "[\"在\"]")
    let cache = CandidateCache()
    let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
    _ = try await gen.generate(context: ctx(), style: .concise)
    _ = try await gen.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 1)   // 第二次命中缓存
}

@Test func differentStyleMissesCache() async throws {
    let provider = CountingProvider(canned: "[\"在\"]")
    let gen = ReplyGenerator(provider: provider, cache: CandidateCache(), candidateCount: 3)
    _ = try await gen.generate(context: ctx(), style: .concise)
    _ = try await gen.generate(context: ctx(), style: .humorous)
    #expect(provider.calls == 2)   // 风格变 -> 重新生成
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ReplyGeneratorTests`
Expected: 编译失败（`ReplyGenerator` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyGenerator.swift`:
```swift
import Foundation

/// 编排一次候选生成：去重缓存命中则复用，否则组 prompt→调模型→解析→存缓存。
public struct ReplyGenerator: Sendable {
    private let provider: any LLMProvider
    private let cache: CandidateCache
    private let candidateCount: Int

    public init(provider: any LLMProvider, cache: CandidateCache, candidateCount: Int = 3) {
        self.provider = provider
        self.cache = cache
        self.candidateCount = candidateCount
    }

    public func generate(context: ChatContext, style: ReplyStyle) async throws -> [String] {
        let key = ContextHasher.key(for: context) + "|style:" + style.name
            + "|n:\(candidateCount)|instr:" + style.instruction
        if let cached = cache.candidates(forKey: key) { return cached }
        let messages = PromptBuilder.build(context: context, style: style, candidateCount: candidateCount)
        let raw = try await provider.complete(messages: messages)
        let candidates = CandidateParser.parse(raw, max: candidateCount)
        cache.store(candidates, forKey: key)
        return candidates
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全部测试 PASS（含 Phase 1 的 12 个 + 本阶段新增）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): ReplyGenerator 编排（去重缓存+生成+解析）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7：把 ZhiYuCore 接入 App（手动 GUI 一次）

**Files:**
- Modify: `ZhiYu.xcodeproj`（Xcode 自动写入包依赖）
- Create: `ZhiYu/WeChat/CoreSmokeTest.swift`（临时验证 import，可在 Task 9 删）

- [ ] **Step 1: Xcode 添加本地包依赖**（手动）

1. Xcode 打开 `ZhiYu.xcodeproj`。
2. File → Add Package Dependencies… → 左下 "Add Local…" → 选仓库根 `ZhiYuCore` → Add Package。
3. 产品选择里把 `ZhiYuCore` 库勾给 target `ZhiYu` → Add。

- [ ] **Step 2: 写一个使用 ZhiYuCore 的最小文件验证链接**

`ZhiYu/WeChat/CoreSmokeTest.swift`:
```swift
import ZhiYuCore

enum CoreSmokeTest {
    static func sample() -> String {
        let ctx = ChatContext(contactName: "联调", messages: [], draft: "")
        return ContextHasher.key(for: ctx)
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（若报 No such module 'ZhiYuCore'，回 Step 1 重加包）。

- [ ] **Step 4: 提交**

```bash
git add ZhiYu.xcodeproj ZhiYu
git commit -m "build: App 接入本地包 ZhiYuCore" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8：KeychainStore（存/取 OpenAI API Key）

**Files:**
- Create: `ZhiYu/Secrets/KeychainStore.swift`

- [ ] **Step 1: 实现**

`ZhiYu/Secrets/KeychainStore.swift`:
```swift
import Foundation
import Security

/// 极简 Keychain 读写（generic password）。Phase 2 仅存 OpenAI API Key。
enum KeychainStore {
    static let service = "com.liuwentong.ZhiYu"
    static let openAIKeyAccount = "openai.apiKey"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func openAIKey() -> String { get(account: openAIKeyAccount) ?? "" }
    static func setOpenAIKey(_ v: String) { set(v, account: openAIKeyAccount) }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): KeychainStore 存取 OpenAI API Key" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9：WeChatReader（AX 读取 -> ChatContext 适配器）

复用已验证的探针读取逻辑（`WeChatAXProbe.run()` 返回 `ProbeResult`，含 contactName/messages(带 speaker)/draft），映射为 `ZhiYuCore.ChatContext`（丢弃时间分隔行；speaker `.me`→`.me`、其余→`.other`）。

**Files:**
- Create: `ZhiYu/WeChat/WeChatReader.swift`
- Delete: `ZhiYu/WeChat/CoreSmokeTest.swift`（Task 7 的临时文件）

- [ ] **Step 1: 实现适配器**

`ZhiYu/WeChat/WeChatReader.swift`:
```swift
import AppKit
import ZhiYuCore

/// 读取微信当前会话为 ChatContext。复用探针验证过的快速 AX 读取。
@MainActor
enum WeChatReader {
    /// 返回当前会话上下文；读不到返回 nil。
    static func readCurrentContext() -> ChatContext? {
        switch WeChatAXProbe.run() {
        case .failure:
            return nil
        case .success(let r):
            let msgs: [ChatMessage] = r.messages.compactMap { m in
                switch m.speaker {
                case .me:    return ChatMessage(speaker: .me, text: m.text)
                case .other: return ChatMessage(speaker: .other, text: m.text)
                case .separator: return nil   // 时间/系统分隔行不进上下文
                }
            }
            return ChatContext(contactName: r.contactName, messages: msgs, draft: r.draft)
        }
    }
}
```

- [ ] **Step 2: 删除临时验证文件**

Run: `git rm ZhiYu/WeChat/CoreSmokeTest.swift`

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): WeChatReader 将 AX 读取适配为 ChatContext" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10：Inserter（fill / fillAndSend 包装已验证路径）

包装 Phase 1 已验证的 `InserterProbe`：填入用 AX 写值，发送用"激活+聚焦+校验前台/焦点+回车"。

**Files:**
- Create: `ZhiYu/WeChat/Inserter.swift`

- [ ] **Step 1: 实现**

`ZhiYu/WeChat/Inserter.swift`:
```swift
import AppKit

/// 候选落地：仅填入，或填入并发送。复用 Phase 1 验证过的 InserterProbe。
@MainActor
enum Inserter {
    /// 仅填入微信输入框。
    @discardableResult
    static func fill(_ text: String) -> Bool {
        InserterProbe.setText(text)
    }

    /// 填入并发送：AX 写入 → 激活微信 + 聚焦 composer → 校验前台/焦点后回车。
    /// 返回是否已发出回车（写入失败或前台/焦点校验不过则不回车，返回 false）。
    static func fillAndSend(_ text: String, completion: @escaping (Bool) -> Void) {
        let ok = InserterProbe.setText(text)
        _ = InserterProbe.focusComposerAndActivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let written = InserterProbe.composerValue() ?? ""
            guard ok, written.contains(text), InserterProbe.isWeChatFrontFocused() else {
                completion(false); return
            }
            InserterProbe.sendReturn()
            completion(true)
        }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): Inserter 封装填入/填入并发送" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11：生成面板 GeneratePanel + 接入探针窗口（端到端联调）

在探针窗口里加一块"生成区"：API Key（SecureField，存 Keychain）、模型名、风格选择、"生成候选"按钮；点击后读上下文→ReplyGenerator→显示 N 条候选，每条带"填入"/"发送"。

**Files:**
- Create: `ZhiYu/Generate/GeneratePanel.swift`
- Modify: `ZhiYu/Probe/ProbeView.swift`（在底部嵌入 GeneratePanel）

- [ ] **Step 1: 实现生成面板**

`ZhiYu/Generate/GeneratePanel.swift`:
```swift
import SwiftUI
import ZhiYuCore

@MainActor
final class GenerateViewModel: ObservableObject {
    @Published var apiKey: String = KeychainStore.openAIKey()
    @Published var model: String = "gpt-4o"
    @Published var styleIndex: Int = 0
    @Published var status: String = ""
    @Published var candidates: [String] = []
    @Published var isLoading = false

    private let cache = CandidateCache()
    let styles = ReplyStyle.presets

    func saveKey() {
        KeychainStore.setOpenAIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        status = "已保存 API Key 到 Keychain"
    }

    func generate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "请先填写并保存 API Key"; return }
        guard let context = WeChatReader.readCurrentContext(), !context.messages.isEmpty else {
            status = "读不到微信对话（先切到某个会话，且已授权辅助功能）"; return
        }
        let provider = OpenAICompatibleProvider(config: .openAI(model: model), apiKey: key)
        let generator = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
        let style = styles[styleIndex]
        isLoading = true
        status = "生成中…（联系人：\(context.contactName)，\(context.messages.count) 条上下文）"
        candidates = []
        Task {
            do {
                let result = try await generator.generate(context: context, style: style)
                self.candidates = result
                self.status = "完成，\(result.count) 条候选"
            } catch {
                self.status = "失败：\(error)"
            }
            self.isLoading = false
        }
    }

    func fill(_ text: String) {
        Inserter.fill(text)
        status = "已填入：\(text)"
    }

    func send(_ text: String) {
        Inserter.fillAndSend(text) { ok in
            self.status = ok ? "已发送：\(text)" : "未发送（请确认微信在前台且输入框聚焦）"
        }
    }
}

struct GeneratePanel: View {
    @StateObject private var vm = GenerateViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成候选回复").font(.headline)
            HStack {
                SecureField("OpenAI API Key", text: $vm.apiKey)
                Button("保存 Key") { vm.saveKey() }
            }
            HStack {
                TextField("模型", text: $vm.model).frame(width: 160)
                Picker("风格", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in
                        Text(s.name).tag(i)
                    }
                }.frame(width: 160)
                Button(vm.isLoading ? "生成中…" : "生成候选") { vm.generate() }
                    .disabled(vm.isLoading)
            }
            if !vm.status.isEmpty { Text(vm.status).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(vm.candidates.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top) {
                    Text(c).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("填入") { vm.fill(c) }
                    Button("发送") { vm.send(c) }
                }
                .padding(6)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(6)
            }
        }
    }
}
```

- [ ] **Step 2: 在探针窗口嵌入生成面板**

修改 `ZhiYu/Probe/ProbeView.swift` 的 `ProbeView.body`：在 `ScrollView { ... }` **之后**、`.padding()` 之前，于最外层 `VStack` 内追加：
```swift
            Divider()
            GeneratePanel()
```
即把现有 body 改为（节选最外层 VStack 结尾）：
```swift
            ScrollView {
                Text(vm.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Divider()
            GeneratePanel()
        }
        .padding()
        .frame(width: 560, height: 720)
```
（窗口高度由 480 调到 720 以容纳生成区。）

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 真机端到端手动验证**

1. ⌘R 运行 → 打开探针窗口 → 生成区填入你的 OpenAI API Key → "保存 Key"。
2. 微信切到一个会话（建议先用真实对话语境，但发送只在"文件传输助手"测）。
3. 选风格 → "生成候选" → 应显示 3 条候选（status 显示联系人与上下文条数）。
4. 点某条"填入"→ 微信输入框出现该文本；点"发送"→（在文件传输助手）确认发出。
5. 再点一次"生成候选"（同会话、同风格、上下文未变）→ 应秒回（命中去重缓存，不再调用 API）。
**记录：** 候选质量、耗时、缓存是否命中、填入/发送是否正常。

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 生成面板端到端打通 读取→生成→候选→填入/发送" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 收尾
端到端闭环可用后，记录：候选质量是否可用、首字/总耗时、缓存命中行为、OpenAI 之外是否需要尽快加 Anthropic/DeepSeek。据此决定 Phase 3。

## 后续 Roadmap
- **Phase 3 — 候选悬浮面板**：non-activating `NSPanel` 锚定 composer frame（探针已能拿到）、候选卡点填入/点发送、数字键选中、失焦消失。把生成从探针窗口搬到悬浮面板。
- **Phase 4 — 触发与去重产品化**：正式全局快捷键(RegisterEventHotKey 独占) + 可选聚焦自动触发 + 防抖；流式输出。
- **Phase 5 — 设置 UI + 多 Provider**：设置窗口（Provider/Key/模型/风格/快捷键/权限状态）、Anthropic/DeepSeek/自定义兼容端点、按联系人风格覆盖。
- **Phase 6 — OpenAI OAuth**：Sign in with ChatGPT + token 刷新。
- **Phase 7 — OCR 兜底**：ScreenCaptureKit + Vision，AX 失败回退（可开关）。
- **Phase 8 — 打磨/分发**：错误处理、边界、菜单栏正式 UI、必要时 Developer ID 公证。
