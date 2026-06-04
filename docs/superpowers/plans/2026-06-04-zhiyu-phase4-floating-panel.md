# 知语 ZhiYu — Phase 4：候选悬浮面板（双击右⌘触发） 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在微信里**双击右 Command** → 读当前会话 → 用当前配置的 Provider+风格生成 → 在输入框上方弹出**悬浮面板**（点卡片正文=填入、点发送按钮=填入并发送、数字键 1/2/3=填入、Esc/失焦=消失）。把生成从开发态探针窗口搬进真正可日常使用的悬浮面板。

**Architecture:** 纯逻辑（双击判定状态机、AX→AppKit 坐标换算）放 `ZhiYuCore` 走 `swift test` TDD；系统集成（全局 flagsChanged 监听、`.nonactivatingPanel` 悬浮面板、配置共享、生成编排）放 App 走 `xcodebuild` + 真机联调。复用 Phase 1-3 的 WeChatReader(已返回 composer frame)、ReplyGenerator、Provider 工厂、Inserter。

**Tech Stack:** Swift 6.3 / SwiftUI(NSHostingView) / AppKit(NSPanel/NSEvent) / UserDefaults / Swift Testing。目标 macOS 26.5。当前分支 **main**（本项目不开分支，直接在 main 提交）。

**对应 spec:** `docs/superpowers/specs/2026-06-04-zhiyu-wechat-reply-assistant-design.md`（5.7 候选面板 / 5.3 触发）
**前置：** Phase 1-3 完成。已有 `WeChatReader.readCurrentContext() -> ChatContext`、`WeChatAXProbe.run()` 返回的 `inputFrame`(composer 屏幕 frame，AX 左上原点坐标)、`ReplyGenerator`、`GeneratePanel` 的 Provider 工厂逻辑、`Inserter.fill/fillAndSend`。

> 设计取舍（已确认）：触发=双击右⌘；面板用 `.nonactivatingPanel`（可收数字键但不夺微信前台，保证发送生效）；探针窗口的生成面板暂作"设置入口"，正式设置窗口留 Phase 5。

---

## 文件结构
```
ZhiYuCore/Sources/ZhiYuCore/Input/
  DoubleTapDetector.swift     # 双击判定状态机（纯逻辑）
  PanelPositioning.swift      # AX(左上原点) composer frame -> AppKit(左下原点) 面板原点
ZhiYu/
  Config/AppConfig.swift      # 共享配置（providerKind/model/styleIndex，UserDefaults）
  LLM/ProviderFactory.swift   # 由配置构造 any LLMProvider（抽自 GeneratePanel）
  Input/RightCommandDoubleTap.swift  # 全局 flagsChanged 监听右⌘双击 -> onTrigger
  Panel/CandidatePanelView.swift     # 悬浮面板 SwiftUI 内容
  Panel/CandidatePanelController.swift # NSPanel 管理 + 定位 + 生成编排 + 键盘 + 消失
  AppDelegate.swift           # 修改：启动时装监听，触发 -> controller
  Generate/GeneratePanel.swift # 修改：读写 AppConfig + 复用 ProviderFactory
```

---

## Task 1：DoubleTapDetector（双击判定状态机）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Input/DoubleTapDetector.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/DoubleTapDetectorTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/DoubleTapDetectorTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func twoPressesWithinThresholdIsDoubleTap() {
    var d = DoubleTapDetector(threshold: 0.4)
    #expect(d.registerPress(at: 1.00) == false)
    #expect(d.registerPress(at: 1.30) == true)   // 间隔 0.30 < 0.4
}

@Test func twoPressesTooFarApartIsNotDoubleTap() {
    var d = DoubleTapDetector(threshold: 0.4)
    #expect(d.registerPress(at: 1.00) == false)
    #expect(d.registerPress(at: 1.90) == false)  // 间隔 0.90 > 0.4，重置为新的首击
    #expect(d.registerPress(at: 2.10) == true)   // 与上一次间隔 0.20
}

@Test func resetClearsPendingFirstPress() {
    var d = DoubleTapDetector(threshold: 0.4)
    _ = d.registerPress(at: 1.00)
    d.reset()
    #expect(d.registerPress(at: 1.20) == false)  // 已重置，这是新的首击
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter DoubleTapDetectorTests`
Expected: 编译失败（`DoubleTapDetector` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Input/DoubleTapDetector.swift`:
```swift
import Foundation

/// 双击判定：连续两次"按下"间隔不超过 threshold 即为双击。中间被 reset() 打断则重新计。
public struct DoubleTapDetector: Sendable {
    public let threshold: TimeInterval
    private var lastPress: TimeInterval?

    public init(threshold: TimeInterval = 0.4) {
        self.threshold = threshold
    }

    /// 传入本次按下的时间戳（秒，单调递增即可，如 NSEvent.timestamp）。返回是否构成双击。
    public mutating func registerPress(at time: TimeInterval) -> Bool {
        if let last = lastPress, time - last <= threshold {
            lastPress = nil
            return true
        }
        lastPress = time
        return false
    }

    /// 中间夹了别的键 / 需要打断时调用。
    public mutating func reset() { lastPress = nil }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter DoubleTapDetectorTests`
Expected: 3 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): DoubleTapDetector 双击判定状态机" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：PanelPositioning（AX→AppKit 坐标换算）

AX 的 frame 是左上原点（y 向下）；AppKit 窗口原点是左下（y 向上）。面板要贴在 composer 上方。

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Input/PanelPositioning.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/PanelPositioningTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/PanelPositioningTests.swift`:
```swift
import Testing
import Foundation
@testable import ZhiYuCore

@Test func panelSitsAboveComposerInAppKitCoords() {
    // 屏幕高 1000；composer 在 AX 坐标 (x=365, y=734, w=504, h=81)，即距顶 734。
    // composer 顶边的 AppKit y = 1000 - 734 = 266；面板底边应在其上方 gap=8 处 -> originY = 266 + 8 = 274。
    let origin = PanelPositioning.panelOrigin(
        composerAXFrame: CGRect(x: 365, y: 734, width: 504, height: 81),
        screenHeight: 1000, gap: 8)
    #expect(origin.x == 365)
    #expect(origin.y == 274)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter PanelPositioningTests`
Expected: 编译失败（`PanelPositioning` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Input/PanelPositioning.swift`:
```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// AX(左上原点) 的 composer frame 换算为 AppKit(左下原点) 的面板左下角原点，使面板贴在 composer 上方。
public enum PanelPositioning {
    /// - Parameters:
    ///   - composerAXFrame: AX 坐标系下输入框 frame（y 为距屏幕顶部的距离）。
    ///   - screenHeight: 该输入框所在屏幕的高度（点）。
    ///   - gap: 面板底边与 composer 顶边的间隙。
    /// - Returns: AppKit 坐标系（左下原点）下面板的左下角原点。
    public static func panelOrigin(composerAXFrame: CGRect, screenHeight: CGFloat,
                                   gap: CGFloat) -> CGPoint {
        let composerTopAppKit = screenHeight - composerAXFrame.minY
        return CGPoint(x: composerAXFrame.minX, y: composerTopAppKit + gap)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含坐标换算）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): PanelPositioning AX→AppKit 坐标换算" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：AppConfig（共享配置）+ ProviderFactory（抽取）

把 Provider/模型/风格从 GeneratePanel 抽成共享配置 + 工厂，供探针面板与悬浮面板共用。

**Files:**
- Create: `ZhiYu/Config/AppConfig.swift`
- Create: `ZhiYu/LLM/ProviderFactory.swift`
- Modify: `ZhiYu/Generate/GeneratePanel.swift`

- [ ] **Step 1: 写 AppConfig（UserDefaults 共享配置）**

`ZhiYu/Config/AppConfig.swift`:
```swift
import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case chatGPT = "ChatGPT 登录"
    var id: String { rawValue }
}

/// 全局共享配置（非密钥项走 UserDefaults；密钥/token 仍在 Keychain）。
/// 探针生成面板与悬浮面板都读它，保证双击触发时用的是当前所选 Provider/模型/风格。
@MainActor
final class AppConfig {
    static let shared = AppConfig()
    private let d = UserDefaults.standard

    var providerKind: ProviderKind {
        get { ProviderKind(rawValue: d.string(forKey: "providerKind") ?? "") ?? .openAI }
        set { d.set(newValue.rawValue, forKey: "providerKind") }
    }
    var model: String {
        get { d.string(forKey: "model") ?? "gpt-4o" }
        set { d.set(newValue, forKey: "model") }
    }
    var styleIndex: Int {
        get { d.integer(forKey: "styleIndex") }
        set { d.set(newValue, forKey: "styleIndex") }
    }
}
```

- [ ] **Step 2: 写 ProviderFactory（抽自 GeneratePanel.makeProvider）**

`ZhiYu/LLM/ProviderFactory.swift`:
```swift
import Foundation
import ZhiYuCore

/// 由当前配置构造一个 LLMProvider。ChatGPT 走 OAuth token；OpenAI/DeepSeek 走 Keychain key。
@MainActor
enum ProviderFactory {
    static func make() async throws -> any LLMProvider {
        let cfg = AppConfig.shared
        switch cfg.providerKind {
        case .openAI:
            let k = KeychainStore.openAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .openAI(model: cfg.model), apiKey: k)
        case .deepSeek:
            let k = KeychainStore.deepSeekKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .deepSeek(model: cfg.model), apiKey: k)
        case .chatGPT:
            guard let tokens = await CodexLoginService.shared.validTokens() else {
                throw ProviderError.missingAPIKey
            }
            return CodexResponsesProvider(accessToken: tokens.accessToken,
                                          accountId: tokens.accountId, model: cfg.model)
        }
    }
}
```

- [ ] **Step 3: 改 GeneratePanel 读写 AppConfig + 复用 ProviderFactory**

在 `ZhiYu/Generate/GeneratePanel.swift`：
1. 删除其内部重复定义的 `enum ProviderKind`（现移到 AppConfig.swift）。
2. `GenerateViewModel` 的 `kind`/`model`/`styleIndex` 改为读写 `AppConfig.shared`（getter/setter 同步到 UserDefaults），例如把 `@Published var kind` 初值设为 `AppConfig.shared.providerKind`，并在 `onKindChange`/选择变化时 `AppConfig.shared.providerKind = kind` 等回写；`onChange`/Picker 绑定相应同步。
3. `makeProvider()` 改为 `try await ProviderFactory.make()`（删除原私有实现），生成前先把 `AppConfig.shared.model = model`、`AppConfig.shared.styleIndex = styleIndex`、`AppConfig.shared.providerKind = kind` 同步好。

> 目标：探针面板成为"设置入口"，任何改动落到 AppConfig；悬浮面板/双击触发只读 AppConfig + ProviderFactory，不依赖探针窗口是否打开。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): AppConfig 共享配置 + ProviderFactory，GeneratePanel 改为设置入口" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：RightCommandDoubleTap（全局右⌘双击监听）

**Files:**
- Create: `ZhiYu/Input/RightCommandDoubleTap.swift`

- [ ] **Step 1: 实现**

`ZhiYu/Input/RightCommandDoubleTap.swift`:
```swift
import AppKit
import ZhiYuCore

/// 全局监听"双击右 Command"。右 Command 的 keyCode = 54。
/// 用 flagsChanged 捕捉右⌘按下边沿；夹了其它键按下则重置，避免 ⌘C/⌘V 误触。
@MainActor
final class RightCommandDoubleTap {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var detector = DoubleTapDetector(threshold: 0.4)
    var onTrigger: (() -> Void)?

    private static let rightCommandKeyCode: UInt16 = 54

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            // 只认右 Command 的"按下"边沿（command 标志此刻为 set）。
            guard event.keyCode == Self.rightCommandKeyCode,
                  event.modifierFlags.contains(.command) else {
                // 右⌘抬起或其它修饰键变化：不计为按下；其它修饰键打断双击。
                if event.keyCode != Self.rightCommandKeyCode { self.detector.reset() }
                return
            }
            if self.detector.registerPress(at: event.timestamp) {
                self.onTrigger?()
            }
        }
        // 任意普通按键按下 -> 打断双击（避免 ⌘+键 组合被当成双击的一半）。
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.reset()
        }
    }

    func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 全局右⌘双击监听 RightCommandDoubleTap" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：候选悬浮面板（视图 + 控制器）

**Files:**
- Create: `ZhiYu/Panel/CandidatePanelView.swift`
- Create: `ZhiYu/Panel/CandidatePanelController.swift`

- [ ] **Step 1: 写面板视图**

`ZhiYu/Panel/CandidatePanelView.swift`:
```swift
import SwiftUI

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var isLoading = true
    @Published var status = ""
    @Published var candidates: [String] = []
    var onFill: (String) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("生成中…") }
                    .padding(8)
            } else if model.candidates.isEmpty {
                Text(model.status.isEmpty ? "没有候选" : model.status)
                    .foregroundStyle(.secondary).padding(8)
            } else {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { i, c in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                        Text(c)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onFill(c) }
                        Button("发送") { model.onSend(c) }
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .cornerRadius(8)
                }
            }
        }
        .padding(8)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: 写控制器（NSPanel + 定位 + 生成 + 键盘 + 消失）**

`ZhiYu/Panel/CandidatePanelController.swift`:
```swift
import AppKit
import SwiftUI
import ZhiYuCore

/// 管理候选悬浮面板：双击触发后 读会话 -> 定位 -> 生成 -> 展示 -> 填入/发送 -> 消失。
@MainActor
final class CandidatePanelController: NSObject, NSWindowDelegate {
    static let shared = CandidatePanelController()

    private var panel: NSPanel?
    private let model = CandidatePanelModel()
    private let cache = CandidateCache()
    private var keyMonitor: Any?

    /// 双击触发入口。
    func trigger() {
        guard let context = WeChatReader.readCurrentContext(), !context.messages.isEmpty,
              let frame = WeChatReader.composerFrame() else {
            NSSound.beep(); return
        }
        showPanel(anchorAXFrame: frame)
        model.isLoading = true
        model.candidates = []
        model.status = ""
        let style = ReplyStyle.presets[min(AppConfig.shared.styleIndex, ReplyStyle.presets.count - 1)]
        Task {
            do {
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: 3)
                let result = try await gen.generate(context: context, style: style)
                self.model.candidates = result
                self.model.isLoading = false
                if result.isEmpty { self.model.status = "模型没有返回候选" }
            } catch {
                self.model.isLoading = false
                self.model.status = "失败：\(error)"
            }
        }
    }

    private func showPanel(anchorAXFrame axFrame: CGRect) {
        model.onFill = { [weak self] t in Inserter.fill(t); self?.dismiss() }
        model.onSend = { [weak self] t in Inserter.fillAndSend(t) { _ in }; self?.dismiss() }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let hosting = NSHostingView(rootView: CandidatePanelView(model: model))
        hosting.layout()
        let size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = hosting
        p.delegate = self

        // 定位：找到 composer 所在屏幕，换算到 AppKit 坐标。
        let screen = screenContaining(axPointTopLeft: CGPoint(x: axFrame.midX, y: axFrame.minY))
            ?? NSScreen.main ?? NSScreen.screens.first
        let screenHeight = screen?.frame.height ?? 1000
        var origin = PanelPositioning.panelOrigin(composerAXFrame: axFrame,
                                                   screenHeight: screenHeight, gap: 8)
        // 面板高度未知前用 fittingSize 估算后再夹到屏内
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        p.makeKey()
        self.panel = p

        installKeyMonitor()
    }

    /// 在面板存活期间用本地监听处理 1/2/3 与 Esc（nonactivatingPanel 下更稳）。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "1", "2", "3":
                if let n = Int(chars), n - 1 < self.model.candidates.count {
                    self.model.onFill(self.model.candidates[n - 1])
                }
                return nil
            case "\u{1B}": // Esc
                self.dismiss(); return nil
            default:
                return event
            }
        }
    }

    func dismiss() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.close()
        panel = nil
    }

    /// 面板失去 key（用户点回微信等）-> 消失。
    func windowDidResignKey(_ notification: Notification) { dismiss() }

    private func screenContaining(axPointTopLeft p: CGPoint) -> NSScreen? {
        // AX 点为左上原点；转 AppKit 后判断落在哪个屏幕。用主屏高换算近似（多屏精确换算 Phase 5 再细化）。
        let h = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: p.x, y: h - p.y)
        return NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
    }
}
```

- [ ] **Step 3: 给 WeChatReader 补 composerFrame() 便捷方法**

在 `ZhiYu/WeChat/WeChatReader.swift` 内追加（复用探针读取）：
```swift
    /// 当前会话输入框的屏幕 frame（AX 左上原点坐标），读不到返回 nil。
    static func composerFrame() -> CGRect? {
        if case .success(let r) = WeChatAXProbe.run() { return r.inputFrame }
        return nil
    }
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（NSPanel/NSHostingView/NSEvent API 若有出入，最小化修正至编译通过）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 候选悬浮面板（视图 + 控制器，定位/键盘/消失）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6：AppDelegate 接线（启动装监听 → 触发面板）

**Files:**
- Modify: `ZhiYu/AppDelegate.swift`

- [ ] **Step 1: 启动时装双击监听并接到控制器**

`ZhiYu/AppDelegate.swift`（整文件替换）:
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let doubleTap = RightCommandDoubleTap()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        doubleTap.onTrigger = {
            CandidatePanelController.shared.trigger()
        }
        doubleTap.start()
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): AppDelegate 启动装右⌘双击监听并触发悬浮面板" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7：真机联调（手动）

- [ ] **Step 1: 先在探针面板里把配置选好**
⌘R 运行 → 打开探针窗口 → 在生成面板里选 Provider（OpenAI/DeepSeek/ChatGPT 登录）、填 key 或登录、选模型/风格。（这会写入 AppConfig。）

- [ ] **Step 2: 双击右⌘ 唤起悬浮面板**
切到微信某会话 → **双击右 Command** → 输入框上方应弹出悬浮面板，显示"生成中…"，随后出 3 条候选。
**记录：** 面板位置对不对（是否贴在输入框上方）、是否出候选、耗时。

- [ ] **Step 3: 选中**
- 点某条正文 → 填入输入框，面板消失。
- 点"发送" → 填入并发送（在"文件传输助手"测），面板消失。
- 按数字键 1/2/3 → 对应候选填入。
- 按 Esc 或点回微信 → 面板消失。
**记录：** 各交互是否如预期；双击灵敏度是否合适（不灵/误触就调 threshold）。

> 常见需微调点：面板 Y 偏移（gap / 多屏换算）、nonactivatingPanel 下数字键是否被本地监听捕获、双击 threshold（0.4s）。把现象发回我据此调。

---

## 自检 / Roadmap
- 自检：ZhiYuCore swift test 全绿；App BUILD SUCCEEDED；双击触发→面板→填入/发送闭环。
- 后续：Phase 5 正式设置窗口（替代探针面板作配置入口）+ 可选聚焦自动触发 + 多屏精确定位 + 流式候选；Phase 6+ 按联系人风格、OCR 兜底、分发打包。
