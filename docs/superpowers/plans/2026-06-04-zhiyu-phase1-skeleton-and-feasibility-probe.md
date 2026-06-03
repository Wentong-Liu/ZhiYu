# 知语 ZhiYu — Phase 1：骨架 + 核心包 + 可行性探针 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭好菜单栏 App 骨架与带单测的核心逻辑包，并用探针实证验证"微信 AX 读取 / 输入框定位 / 文本写入 / 模拟发送"是否可行——这是整个项目最高风险点，必须先验证再投入后续。

**Architecture:** 纯逻辑（模型 / 去重 hash / 候选缓存）放进独立本地 SPM 包 `ZhiYuCore`，用 `swift test` 跑 TDD；系统集成（菜单栏 / 辅助功能 / AX 读写 / CGEvent / 悬浮窗）放在 Xcode App target `ZhiYu/`（工程已启用文件系统同步组，新建 `.swift` 自动入编译），用 `xcodebuild` 编译验证 + 手动探针验证。**Phase 1 探针为独立验证代码、不依赖 `ZhiYuCore`**（见「执行说明」），二者在 Phase 2 才汇合。

**Tech Stack:** Swift 6.3 / SwiftUI（MenuBarExtra）/ AppKit / ApplicationServices（Accessibility）/ CGEvent / Swift Package Manager + Swift Testing。目标 macOS 26.5。

**对应 spec:** `docs/superpowers/specs/2026-06-04-zhiyu-wechat-reply-assistant-design.md`

---

## 执行说明（UltraCode 自动化运行；优先级高于下方个别代码块）

为让 Phase 1 全程可由命令行（`swift test` + `xcodebuild`）验证、无需 Xcode GUI：

1. **Task 7「把 ZhiYuCore 接入 App」移到 Phase 2**，Phase 1 跳过。
2. **Phase 1 探针（Task 8/9 及之后）不 `import ZhiYuCore`**，改用 App 内本地轻量结构承载读取结果；`ZhiYuCore` 包仍独立用 `swift test` 验证。凡 Task 8/9 代码里用到 `ChatContext`/`ChatMessage` 之处，一律替换为以下本地类型：

```swift
// 定义在 WeChatAXProbe 内
struct Message { let isMe: Bool; let text: String }
struct ProbeResult {
    var contactName: String
    var messages: [Message]
    var draft: String
    var inputFrame: CGRect?
    var inputFocused: Bool
    var rawLines: [String]
}
```

`ProbeViewModel.runAXProbe()` 据此用 `r.contactName` / `r.draft` / `r.messages`（元素含 `isMe`、`text`）/ `r.inputFocused` / `r.inputFrame` / `r.rawLines` 渲染，不再访问 `r.context.*`。

---

## 文件结构

### 本地 SPM 包 `ZhiYuCore/`（放在仓库根，**不在** `ZhiYu/` 内，避免被同步组重复编译）
```
ZhiYuCore/
  Package.swift
  Sources/ZhiYuCore/
    Models/
      ChatMessage.swift     # 一条消息：说话人 + 文本
      ChatContext.swift     # 一段对话上下文：联系人 + 消息列表 + 草稿
    Cache/
      ContextHasher.swift   # 由 (联系人+规整消息+草稿) 算稳定 SHA256 key
      CandidateCache.swift  # 内存候选缓存 key -> [候选]
  Tests/ZhiYuCoreTests/
    ContextHasherTests.swift
    CandidateCacheTests.swift
    ModelsTests.swift
```

### App `ZhiYu/`（同步组自动入编译）
```
ZhiYu/
  ZhiYuApp.swift            # 修改：MenuBarExtra + 探针 Window
  AppDelegate.swift         # 新增：启动时设为 .accessory（无 Dock 图标）
  MenuBar/
    MenuBarContent.swift    # 菜单内容：打开探针窗口 / 退出
  Permissions/
    AccessibilityAuthorizer.swift  # 辅助功能权限检查/申请/打开设置
  Probe/
    WeChatAXProbe.swift     # 遍历微信 AX 树，抽取联系人/消息/输入框
    InserterProbe.swift     # 写入输入框（AX/粘贴）+ 模拟回车发送
    GlobalHotkey.swift      # 全局快捷键 ⌥⌘R 触发探针
    ProbeView.swift         # 探针调试窗口（按钮 + 输出）
  ContentView.swift         # 删除（默认模板，不再需要）
```

---

## Phase 1 无需 Xcode GUI 手动操作
- 探针不依赖 `ZhiYuCore`，因此 Phase 1 **不需要**把本地包接入 App（该步骤移到 Phase 2 起步）。Phase 1 全部代码可用 `swift test` 与 `xcodebuild` 验证。

## 已知开发期摩擦（执行时心里有数）
- **辅助功能权限**：每次重新编译，App 二进制变化可能导致已授予的"辅助功能"信任失效、需重新勾选。可在工程里设固定签名（ad-hoc 固定身份/开发者证书）缓解；Phase 1 先接受"必要时去系统设置重新勾选"。
- 所有"写入 / 发送 / 模拟按键"探针**只在「文件传输助手」会话里测试**，绝不拿真人对话试，避免误发。

---

## Task 1：创建 `ZhiYuCore` 本地 SPM 包骨架

**Files:**
- Create: `ZhiYuCore/Package.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Placeholder.swift`
- Create: `ZhiYuCore/Tests/ZhiYuCoreTests/SanityTests.swift`

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZhiYuCore",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "ZhiYuCore", targets: ["ZhiYuCore"]),
    ],
    targets: [
        .target(name: "ZhiYuCore"),
        .testTarget(name: "ZhiYuCoreTests", dependencies: ["ZhiYuCore"]),
    ]
)
```

- [ ] **Step 2: 写一个占位源文件**（SPM 要求 target 至少有一个源文件）

`ZhiYuCore/Sources/ZhiYuCore/Placeholder.swift`:
```swift
// 占位文件，后续任务会加入真正的类型；保留以确保 target 可编译。
enum ZhiYuCorePlaceholder {}
```

- [ ] **Step 3: 写 sanity 测试（先红）**

`ZhiYuCore/Tests/ZhiYuCoreTests/SanityTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func packageBuildsAndTestsRun() {
    #expect(1 + 1 == 2)
}
```

- [ ] **Step 4: 运行测试，确认绿**

Run: `cd ZhiYuCore && swift test`
Expected: 编译通过，`packageBuildsAndTestsRun` PASS（"1 test passed"）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): 初始化 ZhiYuCore 本地 SPM 包骨架" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：核心模型 `ChatMessage` / `ChatContext`

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Models/ChatMessage.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/Models/ChatContext.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ModelsTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ModelsTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func chatContextIsValueEquatable() {
    let a = ChatContext(
        contactName: "张三",
        messages: [ChatMessage(speaker: .other, text: "在吗"),
                   ChatMessage(speaker: .me, text: "在")],
        draft: "稍等"
    )
    let b = ChatContext(
        contactName: "张三",
        messages: [ChatMessage(speaker: .other, text: "在吗"),
                   ChatMessage(speaker: .me, text: "在")],
        draft: "稍等"
    )
    #expect(a == b)
    #expect(a.messages.first?.speaker == .other)
}

@Test func chatContextRoundTripsThroughCodable() throws {
    let original = ChatContext(
        contactName: "李四",
        messages: [ChatMessage(speaker: .me, text: "你好")],
        draft: ""
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ChatContext.self, from: data)
    #expect(decoded == original)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ModelsTests`
Expected: 编译失败（`ChatContext` / `ChatMessage` 未定义）。

- [ ] **Step 3: 实现模型**

`ZhiYuCore/Sources/ZhiYuCore/Models/ChatMessage.swift`:
```swift
import Foundation

/// 一条聊天消息。
public struct ChatMessage: Codable, Equatable, Sendable {
    /// 说话人：自己或对方。
    public enum Speaker: String, Codable, Sendable {
        case me
        case other
    }

    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
```

`ZhiYuCore/Sources/ZhiYuCore/Models/ChatContext.swift`:
```swift
import Foundation

/// 一次回复生成所需的对话上下文。
public struct ChatContext: Codable, Equatable, Sendable {
    /// 当前聊天对象名称（窗口标题 / 会话名）。
    public let contactName: String
    /// 按时间顺序的可见消息。
    public let messages: [ChatMessage]
    /// 输入框中已有的草稿（可能为空）。
    public let draft: String

    public init(contactName: String, messages: [ChatMessage], draft: String) {
        self.contactName = contactName
        self.messages = messages
        self.draft = draft
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter ModelsTests`
Expected: 2 个测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): 加入 ChatMessage / ChatContext 模型" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：去重 hash `ContextHasher`（草稿纳入 key）

实现 spec 第 5.4 节修正后的设计：缓存 key = `(联系人 + 规整化消息 + 草稿)` 的稳定 SHA256。

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Cache/ContextHasher.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ContextHasherTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ContextHasherTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

private func ctx(contact: String = "张三",
                 msgs: [ChatMessage] = [ChatMessage(speaker: .other, text: "在吗")],
                 draft: String = "") -> ChatContext {
    ChatContext(contactName: contact, messages: msgs, draft: draft)
}

@Test func sameContextProducesSameKey() {
    #expect(ContextHasher.key(for: ctx()) == ContextHasher.key(for: ctx()))
}

@Test func keyIsStableHexOfFixedLength() {
    let key = ContextHasher.key(for: ctx())
    #expect(key.count == 64)                          // SHA256 hex
    #expect(key.allSatisfy { $0.isHexDigit })
}

@Test func differentDraftProducesDifferentKey() {
    let a = ContextHasher.key(for: ctx(draft: "稍等"))
    let b = ContextHasher.key(for: ctx(draft: "马上到"))
    #expect(a != b)                                   // 这是修正的核心：草稿影响 key
}

@Test func differentContactProducesDifferentKey() {
    #expect(ContextHasher.key(for: ctx(contact: "张三")) != ContextHasher.key(for: ctx(contact: "李四")))
}

@Test func whitespaceNoiseInMessagesIsNormalizedAway() {
    let clean = ctx(msgs: [ChatMessage(speaker: .other, text: "在吗")])
    let noisy = ctx(msgs: [ChatMessage(speaker: .other, text: "  在吗  ")])
    #expect(ContextHasher.key(for: clean) == ContextHasher.key(for: noisy))
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ContextHasherTests`
Expected: 编译失败（`ContextHasher` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Cache/ContextHasher.swift`:
```swift
import Foundation
import CryptoKit

/// 由对话上下文计算稳定、可测的缓存 key。
///
/// key 纳入 (联系人 + 规整化消息 + 草稿)。草稿必须纳入：它是回复生成的 prompt 输入，
/// 若不计入则改了草稿会命中过时候选。
public enum ContextHasher {
    public static func key(for context: ChatContext) -> String {
        var parts: [String] = []
        parts.append("contact:" + normalize(context.contactName))
        for m in context.messages {
            parts.append(m.speaker.rawValue + ":" + normalize(m.text))
        }
        parts.append("draft:" + normalize(context.draft))
        let joined = parts.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉首尾空白、把内部连续空白折叠为单空格，消除无意义抖动。
    private static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter ContextHasherTests`
Expected: 5 个测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): ContextHasher 计算缓存 key（草稿纳入）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：内存候选缓存 `CandidateCache`

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Cache/CandidateCache.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/CandidateCacheTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/CandidateCacheTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func missingKeyReturnsNil() {
    let cache = CandidateCache()
    #expect(cache.candidates(forKey: "nope") == nil)
}

@Test func storedCandidatesAreReturned() {
    let cache = CandidateCache()
    cache.store(["好的", "收到", "马上"], forKey: "k1")
    #expect(cache.candidates(forKey: "k1") == ["好的", "收到", "马上"])
}

@Test func storeOverwritesSameKey() {
    let cache = CandidateCache()
    cache.store(["旧"], forKey: "k1")
    cache.store(["新"], forKey: "k1")
    #expect(cache.candidates(forKey: "k1") == ["新"])
}

@Test func clearEmptiesCache() {
    let cache = CandidateCache()
    cache.store(["x"], forKey: "k1")
    cache.clear()
    #expect(cache.candidates(forKey: "k1") == nil)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter CandidateCacheTests`
Expected: 编译失败（`CandidateCache` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Cache/CandidateCache.swift`:
```swift
import Foundation

/// 进程内候选缓存：key（来自 ContextHasher）-> 候选回复列表。
/// 仅存内存，App 退出即清（符合 spec 隐私要求：不持久化聊天内容）。
public final class CandidateCache: @unchecked Sendable {
    private var storage: [String: [String]] = [:]
    private let lock = NSLock()

    public init() {}

    public func candidates(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func store(_ candidates: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = candidates
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全部测试 PASS（sanity + models + hasher + cache）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): 加入内存候选缓存 CandidateCache" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：App 改为菜单栏常驻（无 Dock 图标）

**Files:**
- Create: `ZhiYu/AppDelegate.swift`
- Create: `ZhiYu/MenuBar/MenuBarContent.swift`
- Modify: `ZhiYu/ZhiYuApp.swift`
- Delete: `ZhiYu/ContentView.swift`

- [ ] **Step 1: 写 AppDelegate（启动设为 accessory）**

`ZhiYu/AppDelegate.swift`:
```swift
import AppKit

/// 把 App 设为菜单栏代理（无 Dock 图标、不抢主窗口焦点）。
/// 用运行时 activationPolicy(.accessory) 实现，避免改 pbxproj/Info.plist。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 2: 写菜单内容**

`ZhiYu/MenuBar/MenuBarContent.swift`:
```swift
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开探针窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "probe")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
```

- [ ] **Step 3: 改写 ZhiYuApp（MenuBarExtra + 探针 Window）**

`ZhiYu/ZhiYuApp.swift`:
```swift
import SwiftUI

@main
struct ZhiYuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("知语", systemImage: "bubble.left.and.bubble.right") {
            MenuBarContent()
        }
        Window("知语 · 探针", id: "probe") {
            ProbeView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // 启动不自动弹窗，仅菜单点击时打开
    }
}
```

- [ ] **Step 4: 删除默认 ContentView**

Run: `git rm ZhiYu/ContentView.swift`

> 注意：此时 `ProbeView` 还不存在，下个任务前工程无法编译——这是预期的。本任务的编译验证放在引入 `ProbeView` 占位之后。先补一个最小占位，保证本任务可独立编译通过：

- [ ] **Step 5: 写 ProbeView 最小占位**

`ZhiYu/Probe/ProbeView.swift`:
```swift
import SwiftUI

struct ProbeView: View {
    var body: some View {
        Text("探针窗口（占位）— 功能在后续任务加入")
            .padding()
            .frame(width: 560, height: 480)
    }
}
```

- [ ] **Step 6: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 运行手动验证**

在 Xcode 里按 ⌘R 运行。确认：
1. 菜单栏出现"对话气泡"图标；
2. Dock **没有** ZhiYu 图标；
3. 点菜单栏图标 → 出现"打开探针窗口 / 退出知语"；
4. 点"打开探针窗口" → 弹出占位窗口；点"退出知语" → App 退出。

- [ ] **Step 8: 提交**

```bash
git add ZhiYu && git rm --cached --ignore-unmatch ZhiYu/ContentView.swift
git commit -m "feat(app): 改为菜单栏常驻 App + 探针窗口骨架" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6：辅助功能权限检查与引导

**Files:**
- Create: `ZhiYu/Permissions/AccessibilityAuthorizer.swift`
- Modify: `ZhiYu/MenuBar/MenuBarContent.swift`

- [ ] **Step 1: 写权限工具**

`ZhiYu/Permissions/AccessibilityAuthorizer.swift`:
```swift
import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限的检查 / 申请 / 跳转设置。
enum AccessibilityAuthorizer {
    /// 当前是否已被信任。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示（首次会引导用户去"系统设置"勾选）。
    static func promptIfNeeded() {
        // 用字面量 key 避免不同 SDK 下 kAXTrustedCheckOptionPrompt 的 CFString/Unmanaged 类型歧义
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 直接打开"系统设置 → 隐私与安全性 → 辅助功能"。
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: 菜单加"辅助功能权限"项**

`ZhiYu/MenuBar/MenuBarContent.swift`（整文件替换）:
```swift
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AccessibilityAuthorizer.isTrusted ? "辅助功能：已授权 ✓" : "辅助功能：去授权…") {
            if AccessibilityAuthorizer.isTrusted {
                AccessibilityAuthorizer.openSettings()
            } else {
                AccessibilityAuthorizer.promptIfNeeded()
                AccessibilityAuthorizer.openSettings()
            }
        }
        Button("打开探针窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "probe")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 运行手动验证**

运行后点菜单栏 → "辅助功能：去授权…"：确认弹出系统授权提示且打开了"辅助功能"设置面板。在设置里勾选 ZhiYu（或把它拖入）。重启 App 后菜单项应显示"已授权 ✓"。

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 辅助功能权限检查与引导" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7：（已移至 Phase 2，Phase 1 跳过）

把本地包 `ZhiYuCore` 接入 App（Xcode 加本地包依赖）原计划在此。但 **Phase 1 探针不依赖该包**（见顶部「执行说明」），因此此步骤推迟到 Phase 2 起步。Phase 1 不执行本任务。

---

## Task 8：微信 AX 读取探针 `WeChatAXProbe`

> ⚠️ **实际实现以顶部「执行说明」为准**：探针不 `import ZhiYuCore`，用本地 `Message`/`ProbeResult`；下方代码块里的 `ChatContext`/`ChatMessage`/`r.context.*` 为旧示意，已被覆盖。
>
> 核心可行性验证之一：能否从微信 AX 树读到联系人、可见消息（并按 x 坐标区分我/对方）、输入框 frame/焦点/草稿。

**Files:**
- Create: `ZhiYu/Probe/WeChatAXProbe.swift`

- [ ] **Step 1: 实现 AX 探针**

`ZhiYu/Probe/WeChatAXProbe.swift`:
```swift
import AppKit
import ApplicationServices
import ZhiYuCore

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

    struct ProbeResult {
        var context: ChatContext
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
        let messages: [ChatMessage] = texts
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                let speaker: ChatMessage.Speaker = item.frame.midX > midX ? .me : .other
                return ChatMessage(speaker: speaker, text: item.text)
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

        let context = ChatContext(contactName: title, messages: messages, draft: draft)
        let rawLines = texts.map { "x=\(Int($0.frame.midX))  \($0.text)" }
        return .success(ProbeResult(context: context,
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
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(probe): 微信 AX 读取探针 WeChatAXProbe" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9：探针窗口接 AX 探针并展示

> ⚠️ 下方代码块为旧示意；实际按顶部「执行说明」用本地类型渲染（`r.contactName` / `r.draft` / `r.messages`(含 `isMe`,`text`) / `r.rawLines`），不 `import ZhiYuCore`、不访问 `r.context.*`。

**Files:**
- Modify: `ZhiYu/Probe/ProbeView.swift`

- [ ] **Step 1: 实现 ViewModel + 窗口 UI**

`ZhiYu/Probe/ProbeView.swift`（整文件替换）:
```swift
import SwiftUI
import ZhiYuCore

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var output: String = "把微信切到某个会话，再点「运行 AX 探针」"

    func runAXProbe() {
        switch WeChatAXProbe.run() {
        case .success(let r):
            var lines = [
                "联系人: \(r.context.contactName)",
                "输入框焦点: \(r.inputFocused)",
                "输入框 frame: \(r.inputFrame.map { "\($0)" } ?? "nil")",
                "草稿: 「\(r.context.draft)」",
                "—— 解析后的消息 (\(r.context.messages.count)) ——",
            ]
            lines += r.context.messages.map { "\($0.speaker == .me ? "我  " : "对方") | \($0.text)" }
            lines.append("—— 原始可见文本 + x 坐标 ——")
            lines += r.rawLines
            output = lines.joined(separator: "\n")
        case .failure(let e):
            output = "失败: \(e)"
        }
    }
}

struct ProbeView: View {
    @StateObject private var vm = ProbeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("运行 AX 探针") { vm.runAXProbe() }
            }
            ScrollView {
                Text(vm.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 运行手动验证（关键探针结论 ①）**

前置：已授予辅助功能权限；微信已登录并打开一个会话（建议"文件传输助手"，先发几条文字）。
操作：运行 App → 打开探针窗口 → 切到微信选中会话 → 回到探针窗口点"运行 AX 探针"。
**记录以下结论到本任务备注：**
1. 联系人名是否正确读到？
2. "解析后的消息"里能读到几条？文本是否完整？
3. 我/对方区分是否准确（看"原始可见文本 + x 坐标"，验证 x 坐标能否区分左右）？
4. 输入框 frame 是否拿到（非 nil）？焦点状态是否正确？草稿能否读到？

> 这一步的结论直接决定 Phase 2+ 的设计。如果消息读不全 / 说话人区分不准 / 输入框拿不到，需在 Phase 1 收尾时评估是否启用 OCR 兜底或调整策略。

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(probe): 探针窗口展示微信 AX 读取结果" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10：写入输入框探针 `InserterProbe.setText`

**Files:**
- Create: `ZhiYu/Probe/InserterProbe.swift`
- Modify: `ZhiYu/Probe/ProbeView.swift`

- [ ] **Step 1: 实现写入（AX 优先）**

`ZhiYu/Probe/InserterProbe.swift`:
```swift
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
```

- [ ] **Step 2: 探针窗口加按钮**

在 `ZhiYu/Probe/ProbeView.swift` 的 `ProbeViewModel` 内加方法：
```swift
    func insertViaAX() {
        let ok = InserterProbe.setText("【知语测试】这条是 AX 写入测试")
        output = "AX 写入结果: \(ok)（去微信输入框看是否出现文本）"
    }
```
并在 `ProbeView` 的 `HStack` 里加按钮：
```swift
                Button("AX 写入输入框") { vm.insertViaAX() }
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 运行手动验证（关键探针结论 ②）**

微信切到"文件传输助手" → 探针窗口点"AX 写入输入框"。
**记录结论：** 微信输入框是否出现"【知语测试】这条是 AX 写入测试"？返回值 true/false？
（若 AX 写入失败/无效，Task 11 的粘贴兜底就是替代方案。）

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(probe): AX 写入输入框探针" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11：粘贴兜底 + 模拟回车发送

**Files:**
- Modify: `ZhiYu/Probe/InserterProbe.swift`
- Modify: `ZhiYu/Probe/ProbeView.swift`

- [ ] **Step 1: 加粘贴兜底与发送**

在 `ZhiYu/Probe/InserterProbe.swift` 的 `enum InserterProbe` 内追加：
```swift
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
```

- [ ] **Step 2: 探针窗口加按钮**

在 `ProbeViewModel` 内加：
```swift
    func pasteViaClipboard() {
        InserterProbe.pasteText("【知语测试】这条是粘贴兜底测试")
        output = "已触发粘贴（去微信输入框看是否出现文本）"
    }

    func insertAndSend() {
        let ok = InserterProbe.setText("【知语测试】这条是写入并发送测试")
        InserterProbe.sendReturn()
        output = "写入(\(ok))并已模拟回车，请在「文件传输助手」确认是否发出"
    }
```
在 `ProbeView` 的 `HStack` 里加两个按钮：
```swift
                Button("粘贴兜底") { vm.pasteViaClipboard() }
                Button("写入并发送") { vm.insertAndSend() }
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 运行手动验证（关键探针结论 ③）— 只在「文件传输助手」测试**

1. 微信切到"文件传输助手"。
2. 探针窗口点"粘贴兜底"：确认输入框出现文本、且系统剪贴板随后被恢复。
3. 点"写入并发送"：确认"文件传输助手"里**真的收到**了该条消息（验证模拟回车发送可行）。

**记录结论：** 粘贴兜底是否可用？模拟回车能否触发微信发送？

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(probe): 粘贴兜底 + 模拟回车发送" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12：全局快捷键探针 `GlobalHotkey`

**Files:**
- Create: `ZhiYu/Probe/GlobalHotkey.swift`
- Modify: `ZhiYu/Probe/ProbeView.swift`

- [ ] **Step 1: 实现全局快捷键监听**

`ZhiYu/Probe/GlobalHotkey.swift`:
```swift
import AppKit

/// 探针用全局快捷键监听（⌥⌘R）。基于全局事件监听，不消费事件，仅用于验证可行性；
/// 正式版会换成 RegisterEventHotKey 以独占快捷键。
@MainActor
final class GlobalHotkey {
    private var monitor: Any?
    var onTrigger: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌥⌘R：option + command + R(keyCode 15)
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == [.command, .option], event.keyCode == 15 {
                self?.onTrigger?()
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
```

- [ ] **Step 2: 探针窗口接入快捷键**

在 `ProbeViewModel` 内加属性与方法：
```swift
    private let hotkey = GlobalHotkey()

    func enableHotkey() {
        hotkey.onTrigger = { [weak self] in self?.runAXProbe() }
        hotkey.start()
        output = "已启用全局快捷键 ⌥⌘R：切到微信任意会话后按它，应自动跑一次 AX 探针并刷新这里"
    }
```
在 `ProbeView` 的 `HStack` 里加按钮：
```swift
                Button("启用快捷键 ⌥⌘R") { vm.enableHotkey() }
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 运行手动验证（关键探针结论 ④）**

运行 → 探针窗口点"启用快捷键 ⌥⌘R" → 切到微信某会话 → 按 ⌥⌘R → 回探针窗口看输出是否被刷新成该会话的读取结果。
**记录结论：** 全局快捷键能否在微信前台时触发？

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(probe): 全局快捷键 ⌥⌘R 触发 AX 探针" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 收尾：探针结论汇总

完成 Task 9–12 后，把四项关键结论写成一段小结（追加到本文件末尾或新建 `docs/superpowers/notes/2026-06-04-probe-findings.md`）：

| 验证项 | 结论（可行 / 部分可行 / 不可行） | 备注 |
|--------|-------------------------------|------|
| AX 读取联系人 + 可见消息 | | 消息完整度、读到几条 |
| 说话人区分（x 坐标） | | 准确率 |
| 输入框 frame / 焦点 / 草稿 | | 能否用于面板锚定与草稿读取 |
| AX 写入 / 粘贴兜底 | | 哪个可用 |
| 模拟回车发送 | | 是否真能发出 |
| 全局快捷键触发 | | |

**决策门：** 据此决定 Phase 2 起 `WeChatReader` 的主路径（纯 AX / AX+OCR），以及 `Inserter` 用 AX 写入还是粘贴兜底。

---

## 后续 Roadmap（各自单独出计划，待探针结论后细化）

- **Phase 2 — 接入 ZhiYuCore + Provider 层（API Key）**：首步把本地包 `ZhiYuCore` 接入 App（Xcode 加本地包依赖，原 Task 7）。然后 `ProviderManager` 统一抽象（name/baseURL/authMode/model）、Keychain 存 key、OpenAI 兼容请求/响应解析（用 URLProtocol mock 做 TDD）、模型选择。产出：能用一个真实 API Key 调通一次补全。
- **Phase 3 — 主闭环**：`TriggerEngine`（正式快捷键 + 可选聚焦触发）+ `WeChatReader`（探针逻辑产品化）+ `ContextHasher`/`CandidateCache` 去重 + `ReplyGenerator`（风格+语言+草稿组 prompt）。产出：触发→读取→去重→生成→拿到 N 条候选（先 console 验证）。
- **Phase 4 — 候选悬浮面板**：non-activating `NSPanel` 锚定输入框、候选卡（点填入 / 点发送按钮）、数字键选中、失焦消失。
- **Phase 5 — 设置 UI + 风格**：SwiftUI 设置窗口（Provider/模型/风格/快捷键/触发/OCR/权限状态）、预设+自定义风格、全局默认 +（nice-to-have）按联系人覆盖。
- **Phase 6 — OpenAI OAuth**：Sign in with ChatGPT 授权流程 + token 刷新 + Keychain。
- **Phase 7 — OCR 兜底**：ScreenCaptureKit 截图 + Vision OCR，作为 AX 失败回退（可开关）。
- **Phase 8 — 打磨**：错误处理、边界、体验、固定签名以减少权限反复授予。
