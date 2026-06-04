# 知语 ZhiYu — Phase 8：图片/表情识别（截图 + 多模态） 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 对方发图片/表情包时，截取该气泡区域作为图像，连同文本上下文一起发给视觉模型（ChatGPT 登录走 Codex Responses 的 input_image），让候选能针对图片内容来回；不发图的 Provider 仅保留 `[图片]`/`[表情]` 文本（优雅降级）。

**Architecture:** 数据类型/prompt/Codex 请求改造放 ZhiYuCore(TDD)；屏幕截图(ScreenCaptureKit)、屏幕录制权限、图片/表情 AX 检测与捕获放 App。捕获是异步的：先同步读 AX 快照(文本+composer frame+图片 frame 列表)并弹出 loading 面板，再在生成前异步截图。

**Tech Stack:** Swift 6.3 / ScreenCaptureKit / CoreGraphics / SwiftUI / Swift Testing。分支 **main**。

**前置（已用诊断确认的微信 AX 结构）：**
- 表情包：`AXUnknown「X:发送了一个表情」` + 子 `AXImage`(精确 frame)。
- 图片：`AXUnknown「X:发送了一个图片」`，无子 AXImage，截该 AXUnknown 的 frame。
- 文本内联 emoji（如 `[流泪]`）属文本，不处理。
- 现有：`ChatContext`/`LLMMessage`/`PromptBuilder`/`CodexResponsesProvider`/`VoiceText`(ZhiYuCore)；`WeChatAXProbe`(含 readSnapshot/Message/导航/frame)、`WeChatReader`、`CandidatePanelController`(App)。AX frame 为全局左上原点坐标。

> 范围：本期图像仅发给 CodexResponsesProvider(ChatGPT 登录)。OpenAICompatibleProvider 不发图（忽略 imageDataURLs），有图时上下文仅保留 `[图片]`/`[表情]` 文本。捕获最多取最近 2 张图片/表情（控 token 与耗时）。

---

## Task 1：ZhiYuCore——上下文/消息携带图片 + VoiceText 标记图片/表情

**Files:**
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Models/ChatContext.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Provider/LLMMessage.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/VoiceText.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ImageContextTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ImageContextTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func chatContextCarriesImageDataURLs() {
    let c = ChatContext(contactName: "张婷",
                        messages: [ChatMessage(speaker: .other, text: "[图片]")],
                        draft: "",
                        imageDataURLs: ["data:image/png;base64,AAA"])
    #expect(c.imageDataURLs == ["data:image/png;base64,AAA"])
}

@Test func chatContextDefaultsToNoImages() {
    let c = ChatContext(contactName: "x", messages: [], draft: "")
    #expect(c.imageDataURLs.isEmpty)
}

@Test func llmMessageCarriesImages() {
    let m = LLMMessage(role: .user, content: "hi", imageDataURLs: ["data:img"])
    #expect(m.imageDataURLs == ["data:img"])
    #expect(LLMMessage(role: .user, content: "hi").imageDataURLs.isEmpty)
}

@Test func voiceTextMarksImageAndSticker() {
    #expect(VoiceText.clean("发送了一个图片") == "[图片]")
    #expect(VoiceText.clean("发送了一个表情") == "[表情]")
    #expect(VoiceText.clean("我感冒了[流泪]") == "我感冒了[流泪]")   // 内联 emoji 不动
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ImageContextTests`
Expected: 编译失败（imageDataURLs 参数不存在）。

- [ ] **Step 3: 实现**

`ChatContext.swift`（整文件替换）:
```swift
import Foundation

/// 一次回复生成所需的对话上下文。
public struct ChatContext: Codable, Equatable, Sendable {
    public let contactName: String
    public let messages: [ChatMessage]
    public let draft: String
    /// 最近图片/表情的截图（base64 data URL），供视觉模型识别；无则空。
    public let imageDataURLs: [String]

    public init(contactName: String, messages: [ChatMessage], draft: String,
                imageDataURLs: [String] = []) {
        self.contactName = contactName
        self.messages = messages
        self.draft = draft
        self.imageDataURLs = imageDataURLs
    }
}
```

`LLMMessage.swift`（整文件替换）:
```swift
import Foundation

/// 发给大模型的一条对话消息。
public struct LLMMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    /// 附带图像（base64 data URL）；仅视觉 Provider 使用，其它忽略。
    public let imageDataURLs: [String]

    public init(role: Role, content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }
}
```

`VoiceText.swift`：在 clean(_:) 里，"发送了一个语音" 分支之后、return text 之前，追加图片/表情标记。具体：把原 `if text.contains("发送了一个语音") { return "[语音]" }` 之后加：
```swift
        if text.contains("发送了一个图片") { return "[图片]" }
        if text.contains("发送了一个表情") { return "[表情]" }
```
（"已转文字"分支保持最前，语音其次，图片/表情再次，普通文本原样。）

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（新 4 测试 + 既有不破）。

> 注意：LLMMessage 现有 Codable 仍可编码（多了 imageDataURLs 字段）；OpenAIProviderTests 的 chat/completions 请求里会多带空数组 imageDataURLs 字段——若该测试断言请求体不含多余字段而失败，在 OpenAICompatibleProvider 的 RequestBody 里用一个不含 imageDataURLs 的内部 message 结构编码（见 Task 2 备注），保证 chat/completions 请求体不变。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): ChatContext/LLMMessage 携带图片 + VoiceText 标记图片/表情" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：ZhiYuCore——PromptBuilder 附图 + CodexResponsesProvider input_image

**Files:**
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/PromptBuilder.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/OAuth/CodexResponsesProvider.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Provider/OpenAICompatibleProvider.swift`（仅确保 chat/completions 请求体不含图片字段）
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ImageRequestTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ImageRequestTests.swift`:
```swift
import Testing
import Foundation
@testable import ZhiYuCore

@Test func promptBuilderAttachesImagesToUserMessage() {
    let ctx = ChatContext(contactName: "张婷",
                          messages: [ChatMessage(speaker: .other, text: "[图片]")],
                          draft: "",
                          imageDataURLs: ["data:image/png;base64,AAA"])
    let msgs = PromptBuilder.build(context: ctx, style: .concise, candidateCount: 3)
    let user = msgs.last
    #expect(user?.role == .user)
    #expect(user?.imageDataURLs == ["data:image/png;base64,AAA"])
    #expect((user?.content ?? "").contains("图片"))   // 文本里提到对方发了图片
}

@Test func codexResponsesBodyIncludesInputImageWhenPresent() async throws {
    final class Mock: URLProtocol {
        nonisolated(unsafe) static var body: Data = Data()
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Mock.body = request.httpBodyStream.flatMap { s -> Data in
                s.open(); defer { s.close() }
                var d = Data(); let n = 4096; var buf = [UInt8](repeating: 0, count: n)
                while s.hasBytesAvailable { let r = s.read(&buf, maxLength: n); if r <= 0 { break }; d.append(buf, count: r) }
                return d
            } ?? request.httpBody ?? Data()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [Mock.self]
    let session = URLSession(configuration: cfg)
    let p = CodexResponsesProvider(accessToken: "t", accountId: "a", model: "gpt-5.5", session: session)
    let text = try await p.complete(messages: [
        LLMMessage(role: .user, content: "看这张图", imageDataURLs: ["data:image/png;base64,AAA"]),
    ])
    #expect(text == "ok")
    let bodyStr = String(data: Mock.body, encoding: .utf8) ?? ""
    #expect(bodyStr.contains("input_image"))
    #expect(bodyStr.contains("data:image/png;base64,AAA"))
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ImageRequestTests`
Expected: FAIL（user 无 imageDataURLs / body 无 input_image）。

- [ ] **Step 3: 实现**

`PromptBuilder.swift`：在 build(...) 末尾构造返回值处，把图片附到 user 消息，并在有图时于 convo 文本里加一句说明。即返回改为：
```swift
        let hasImages = !context.imageDataURLs.isEmpty
        let convoText = convo + (hasImages ? "\n（对方还发了图片/表情，见附带的图像，请结合图像内容回复。）\n" : "")
        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: convoText, imageDataURLs: context.imageDataURLs),
        ]
```
（其余 system/rhythm/convo 生成逻辑不变；把原先直接 return 的 user 消息替换为上面带 imageDataURLs 的版本。）

`CodexResponsesProvider.swift`：构造 input 时，对每条消息把 imageDataURLs 作为 input_image 追加到 content。把原先 input 映射：
```swift
        let input: [[String: Any]] = messages.filter { $0.role != .system }.map { m in
            let type = (m.role == .assistant) ? "output_text" : "input_text"
            var content: [[String: Any]] = [["type": type, "text": m.content]]
            for url in m.imageDataURLs {
                content.append(["type": "input_image", "image_url": url])
            }
            return ["role": m.role.rawValue, "content": content]
        }
```
（其余 body 字段、headers、SSE 解析不变。）

`OpenAICompatibleProvider.swift`：确保 chat/completions 请求体不受 LLMMessage 新增字段影响——RequestBody 用一个仅含 role+content 的内部结构编码：
```swift
    private struct WireMessage: Encodable { let role: String; let content: String }
    private struct RequestBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let temperature: Double
    }
    // complete(...) 内构造：
    // let wire = messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) }
    // ...RequestBody(model: config.model, messages: wire, temperature: 0.8)
```
（即不再直接编码 [LLMMessage]，避免把 imageDataURLs 发给 chat/completions；OpenAI/DeepSeek 本期不发图。）

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含新测试；OpenAIProviderTests 仍通过——请求体只有 model/messages(role,content)/temperature）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): PromptBuilder 附带图片 + Codex input_image；OpenAI 兼容不发图" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：App——屏幕截图 + 屏幕录制权限

**Files:**
- Create: `ZhiYu/Capture/ScreenCapturer.swift`
- Create: `ZhiYu/Permissions/ScreenRecordingAuthorizer.swift`

- [ ] **Step 1: 实现截图器（ScreenCaptureKit，按全局 rect 截一块）**

`ZhiYu/Capture/ScreenCapturer.swift`:
```swift
import AppKit
import ScreenCaptureKit

@MainActor
enum ScreenCapturer {
    /// 截取全局(左上原点)坐标 rect 区域，返回 PNG 的 data URL；失败返回 nil。
    static func capture(globalRect: CGRect) async -> String? {
        guard globalRect.width > 1, globalRect.height > 1 else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let display = content.displays.first(where: { $0.frame.intersects(globalRect) })
                ?? content.displays.first
            guard let display else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            // sourceRect：相对所在 display 的左上原点、点为单位。
            let local = CGRect(x: globalRect.minX - display.frame.minX,
                               y: globalRect.minY - display.frame.minY,
                               width: globalRect.width, height: globalRect.height)
            cfg.sourceRect = local
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            cfg.width = max(1, Int(local.width * scale))
            cfg.height = max(1, Int(local.height * scale))
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 2: 屏幕录制权限助手**

`ZhiYu/Permissions/ScreenRecordingAuthorizer.swift`:
```swift
import AppKit
import CoreGraphics

enum ScreenRecordingAuthorizer {
    static var isTrusted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): ScreenCapturer(ScreenCaptureKit) + 屏幕录制权限助手" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：App——检测图片/表情、捕获并接入生成；删临时诊断

**Files:**
- Modify: `ZhiYu/Probe/WeChatAXProbe.swift`（Message 加 imageFrame；读取时检测填充；删诊断）
- Modify: `ZhiYu/WeChat/WeChatReader.swift`（snapshot 暴露 imageFrames；异步捕获）
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`（trigger 先弹 loading 再异步截图+生成）
- Modify: `ZhiYu/MenuBar/MenuBarContent.swift`（删"诊断：导出会话AX"；可加屏幕录制权限项）

- [ ] **Step 1: WeChatAXProbe——Message 加 imageFrame，读取时检测，删诊断**

在 `WeChatAXProbe.Message` 加 `let imageFrame: CGRect?`（并更新其 init/所有构造点；parseMessage 产出的 Message 默认 imageFrame=nil）。
在 `readMessages(from:)` 里，对每行：拿到 value 后，若 value（清洗前原文）含 "发送了一个表情" → 在该行子树找 role=="AXImage" 的节点，取其 frame 作为 imageFrame；若含 "发送了一个图片" → 用该行承载文本的叶子节点(或行)的 frame 作为 imageFrame。把 imageFrame 存进 Message。
新增辅助：`findFirstImageFrame(_ el) -> CGRect?`（在子树找 AXImage 的 frame，复用 children/role/frame）。
删除上一次加的临时诊断：`dumpMessageRows()` 与 `dumpNodeAttrs(...)` 及其 MARK 注释段。其余不变。

> parseMessage 仍只负责说话人/文本拆分；imageFrame 在 readMessages 行级填充。Message 是 struct，给它加字段后，readMessages 里构造 Message 的地方要带上 imageFrame；parseMessage 返回的 Message imageFrame 先置 nil，readMessages 拿到后用带 imageFrame 的副本（可加 `Message.with(imageFrame:)` 或直接重建）。

- [ ] **Step 2: WeChatReader——snapshot 暴露图片 frame，提供异步捕获**

`WeChatReader.Snapshot` 增加 `let imageFrames: [CGRect]`（最近最多 2 条图片/表情消息的 imageFrame，按时间顺序）。readSnapshot() 同步构造时：遍历 probe messages，收集非空 imageFrame（取最后 2 个）放入 imageFrames；context 仍为文本（VoiceText.clean 已把图片/表情标成 [图片]/[表情]）。
新增异步方法：
```swift
static func captureImages(_ frames: [CGRect]) async -> [String] {
    var urls: [String] = []
    for f in frames { if let u = await ScreenCapturer.capture(globalRect: f) { urls.append(u) } }
    return urls
}
/// 把已截到的图片附到 context。
static func context(_ base: ChatContext, withImages urls: [String]) -> ChatContext {
    ChatContext(contactName: base.contactName, messages: base.messages, draft: base.draft, imageDataURLs: urls)
}
```

- [ ] **Step 3: CandidatePanelController.trigger——先弹面板再异步截图+生成**

把 trigger() 改为：同步读 snapshot（拿 context+composerFrame+imageFrames）→ 弹 loading 面板 → Task 内：先 `let urls = await WeChatReader.captureImages(snapshot.imageFrames)`，`let ctx = WeChatReader.context(snapshot.context, withImages: urls)`，再 `ReplyGenerator(...).generate(context: ctx, style:)`。其余（modelTag/providerLabel/onFill/onSend/定位）不变。

- [ ] **Step 4: MenuBarContent——删诊断；加屏幕录制权限入口（可选）**

删除"诊断：导出会话AX"按钮及多余 Divider。可在"辅助功能"项下方加一个：
```swift
        Button(ScreenRecordingAuthorizer.isTrusted ? "屏幕录制：已授权 ✓" : "屏幕录制：去授权…（识图需要）") {
            if !ScreenRecordingAuthorizer.isTrusted { ScreenRecordingAuthorizer.request() }
            ScreenRecordingAuthorizer.openSettings()
        }
```

- [ ] **Step 5: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（grep 确认无 dumpMessageRows 残留）。

- [ ] **Step 6: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 检测图片/表情→按 frame 截图→随上下文发给视觉模型；删临时诊断" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：真机联调（手动）

- [ ] **Step 1: 授权屏幕录制**
⌘R → 菜单栏"屏幕录制：去授权…" → 系统设置勾选 ZhiYu → 重启 App。

- [ ] **Step 2: 表情包**
会话里对方发过**表情包** → 双击右⌘ → 候选应能"看懂"表情（针对表情内容回）。记录是否识别、截图是否截对了表情那块。

- [ ] **Step 3: 图片**
会话里对方发过**图片** → 双击右⌘ → 候选应能针对图片内容。记录截图区域是否覆盖到图片（图片气泡可能含留白）。

- [ ] **Step 4: 降级**
切到 DeepSeek/OpenAI Key（不发图）→ 有图时上下文只 `[图片]`，候选不报错。

> 联调重点（可能要迭代）：① 截图坐标是否对准气泡（多屏/缩放下的换算）；② Codex 后端是否接受 input_image（Codex CLI 支持发图，应通；不通则回报错误我调请求格式）；③ 图片气泡留白是否影响识别。把现象/失败信息发我据此调。

## 自检 / Roadmap
- 自检：ZhiYuCore swift test 全绿；App BUILD SUCCEEDED；诊断已删。
- 后续：OpenAI/DeepSeek 视觉支持(image_url)、图片气泡更精准裁剪、聚焦自动触发、打包分发。
