# 知语 ZhiYu — Phase 5：缓存修复 + 视觉重设计 + 设置窗口 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ① 修复"切模型仍命中旧缓存"的 bug（缓存 key 纳入 Provider+模型）；② 候选悬浮面板重做成**深色磨砂 + 流体动效**风格、底部显示当前模型；③ 新建一个好看的**设置窗口**（菜单栏打开）替代开发态探针面板作为配置入口。

**Architecture:** 缓存 key 修复在 `ZhiYuCore`（TDD）；视觉/窗口在 App（SwiftUI）。视觉方向：深色磨砂（`.ultraThinMaterial` + 强制 dark）、紫→青强调渐变、卡片弹簧错落入场 + 悬停高亮。复用 AppConfig/Keychain/CodexLoginService。

**Tech Stack:** Swift 6.3 / SwiftUI / Swift Testing。目标 macOS 26.5。分支 **main**（直接提交）。

**前置：** Phase 1-4 完成。已有 `ReplyGenerator`、`CandidatePanelView/Controller`、`AppConfig`、`GeneratePanel`、`MenuBarContent`、`ZhiYuApp`(MenuBarExtra + Window "probe")、`AccessibilityAuthorizer`、`CodexLoginService`、`KeychainStore`。

---

## Task 1：ReplyGenerator 缓存 key 纳入 modelTag（修复切模型命中旧缓存）

**Files:**
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyGenerator.swift`
- Modify: `ZhiYuCore/Tests/ZhiYuCoreTests/ReplyGeneratorTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `ZhiYuCore/Tests/ZhiYuCoreTests/ReplyGeneratorTests.swift` 末尾追加（复用文件内已有的 `CountingProvider` 与 `ctx()`）：
```swift
@Test func differentModelTagMissesCache() async throws {
    let provider = CountingProvider(canned: "[\"x\"]")
    let cache = CandidateCache()
    let g1 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "deepseek/deepseek-v4-flash")
    _ = try await g1.generate(context: ctx(), style: .concise)
    let g2 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "chatgpt/gpt-5.5")
    _ = try await g2.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 2)   // 不同 modelTag -> 不命中缓存
}

@Test func sameModelTagHitsCache() async throws {
    let provider = CountingProvider(canned: "[\"x\"]")
    let cache = CandidateCache()
    let g1 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "openai/gpt-4o")
    _ = try await g1.generate(context: ctx(), style: .concise)
    let g2 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "openai/gpt-4o")
    _ = try await g2.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 1)   // 同 modelTag -> 命中缓存
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ReplyGeneratorTests`
Expected: 编译失败（init 无 `modelTag` 参数）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/Generation/ReplyGenerator.swift`（整文件替换）:
```swift
import Foundation

/// 编排一次候选生成：去重缓存命中则复用，否则组 prompt→调模型→解析→存缓存。
/// 缓存 key 纳入 modelTag（Provider+模型），切换模型不会误命中旧缓存。
public struct ReplyGenerator: Sendable {
    private let provider: any LLMProvider
    private let cache: CandidateCache
    private let candidateCount: Int
    private let modelTag: String

    public init(provider: any LLMProvider, cache: CandidateCache,
                candidateCount: Int = 3, modelTag: String = "") {
        self.provider = provider
        self.cache = cache
        self.candidateCount = candidateCount
        self.modelTag = modelTag
    }

    public func generate(context: ChatContext, style: ReplyStyle) async throws -> [String] {
        let key = ContextHasher.key(for: context)
            + "|style:" + style.name
            + "|n:\(candidateCount)"
            + "|instr:" + style.instruction
            + "|model:" + modelTag
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
Expected: 全绿（含新的 2 个 modelTag 测试；旧测试用默认 modelTag="" 行为不变）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "fix(core): ReplyGenerator 缓存 key 纳入 modelTag，修复切模型命中旧缓存" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：调用处传 modelTag + 把当前模型标签传进面板

**Files:**
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`
- Modify: `ZhiYu/Generate/GeneratePanel.swift`

- [ ] **Step 1: 在 AppConfig 加一个 modelTag 便捷量**

在 `ZhiYu/Config/AppConfig.swift` 的 `AppConfig` 内追加：
```swift
    /// 缓存区分用：Provider+模型 标签，如 "DeepSeek/deepseek-v4-flash"。
    var modelTag: String { "\(providerKind.rawValue)/\(model)" }
    /// 面板展示用：如 "DeepSeek · deepseek-v4-flash"。
    var providerLabel: String { "\(providerKind.rawValue) · \(model)" }
```

- [ ] **Step 2: CandidatePanelController 传 modelTag**

在 `ZhiYu/Panel/CandidatePanelController.swift` 的 `trigger()` 里，构造 ReplyGenerator 时传 modelTag：
`ReplyGenerator(provider: provider, cache: self.cache, candidateCount: 3, modelTag: AppConfig.shared.modelTag)`。
（`model.providerLabel` 的赋值留到 Task 3——那时 `CandidatePanelModel` 才有该属性。）

- [ ] **Step 3: GeneratePanel 生成时也传 modelTag**

在 `ZhiYu/Generate/GeneratePanel.swift` 的 `generate()` 里构造 ReplyGenerator 处加 `modelTag: AppConfig.shared.modelTag`（同步 AppConfig 之后）。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 候选生成传 modelTag，面板携带当前模型标签" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：候选悬浮面板重设计（深色磨砂 + 流体动效）

**Files:**
- Modify: `ZhiYu/Panel/CandidatePanelView.swift`（整文件替换）
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`（设 providerLabel 一行）

> `CandidatePanelModel` 增加 `providerLabel`；视图改为深色磨砂卡片、紫→青强调渐变、弹簧错落入场、悬停高亮、数字徽标、发送按钮、底部模型小字。`CandidatePanelView.swift` 里已含更新后的 `CandidatePanelModel`（带 `providerLabel`）。

- [ ] **Step 1: 整文件替换**

`ZhiYu/Panel/CandidatePanelView.swift`:
```swift
import SwiftUI
import Combine

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var isLoading = true
    @Published var status = ""
    @Published var candidates: [String] = []
    @Published var providerLabel = ""
    var onFill: (String) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

private let accentGradient = LinearGradient(
    colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.27, green: 0.79, blue: 0.96)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel
    @State private var appeared = false
    @State private var hoverIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(14)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(accentGradient).frame(width: 9, height: 9)
            Text("知语 · 候选回复").font(.headline)
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("生成中…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if model.candidates.isEmpty {
            Text(model.status.isEmpty ? "没有候选" : model.status)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { i, c in
                    card(index: i, text: c)
                }
            }
        }
    }

    private func card(index i: Int, text c: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(accentGradient))
            Text(c)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { model.onFill(c) }
            Button { model.onSend(c) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Circle().fill(accentGradient))
            }
            .buttonStyle(.plain)
            .help("填入并发送")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(hoverIndex == i ? 0.13 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    hoverIndex == i ? AnyShapeStyle(accentGradient) : AnyShapeStyle(.white.opacity(0.07)),
                    lineWidth: 1)
        )
        .shadow(color: hoverIndex == i ? .purple.opacity(0.25) : .clear, radius: 10, y: 4)
        .scaleEffect(hoverIndex == i ? 1.015 : 1.0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(i) * 0.06), value: appeared)
        .animation(.easeOut(duration: 0.14), value: hoverIndex)
        .onHover { inside in hoverIndex = inside ? i : (hoverIndex == i ? nil : hoverIndex) }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !model.providerLabel.isEmpty {
                Circle().fill(accentGradient).frame(width: 5, height: 5)
                Text(model.providerLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("1·2·3 选中  ·  Esc 关闭").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
```

- [ ] **Step 2: 控制器设 providerLabel**

在 `ZhiYu/Panel/CandidatePanelController.swift` 的 `trigger()` 里（`model.isLoading = true` 附近）加一行：
```swift
        model.providerLabel = AppConfig.shared.providerLabel
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 候选面板深色磨砂重设计 + 弹簧错落动效 + 模型小字" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：设置窗口（深色磨砂）+ 菜单栏入口

**Files:**
- Create: `ZhiYu/Settings/SettingsView.swift`
- Modify: `ZhiYu/ZhiYuApp.swift`（加 settings Window 场景）
- Modify: `ZhiYu/MenuBar/MenuBarContent.swift`（加"知语设置…"）

- [ ] **Step 1: 写设置视图**

`ZhiYu/Settings/SettingsView.swift`:
```swift
import SwiftUI
import Combine
import ZhiYuCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var kind: ProviderKind { didSet { AppConfig.shared.providerKind = kind; syncForKind() } }
    @Published var model: String { didSet { AppConfig.shared.model = model } }
    @Published var styleIndex: Int { didSet { AppConfig.shared.styleIndex = styleIndex } }
    @Published var apiKey: String = ""
    @Published var status = ""
    @Published var loggedIn = KeychainStore.loadChatGPTTokens() != nil
    let styles = ReplyStyle.presets

    init() {
        kind = AppConfig.shared.providerKind
        model = AppConfig.shared.model
        styleIndex = AppConfig.shared.styleIndex
        switch AppConfig.shared.providerKind {
        case .openAI: apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .chatGPT: apiKey = ""
        }
    }

    func syncForKind() {
        switch kind {
        case .openAI: apiKey = KeychainStore.openAIKey(); if model.isEmpty { model = "gpt-4o" }
        case .deepSeek: apiKey = KeychainStore.deepSeekKey(); model = "deepseek-v4-flash"
        case .chatGPT: model = "gpt-5.5"
        }
    }
    func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openAI: KeychainStore.setOpenAIKey(k); status = "已保存 OpenAI Key"
        case .deepSeek: KeychainStore.setDeepSeekKey(k); status = "已保存 DeepSeek Key"
        case .chatGPT: break
        }
    }
    func login() {
        status = "正在打开浏览器登录…"
        CodexLoginService.shared.login { [weak self] r in
            switch r {
            case .success: self?.loggedIn = true; self?.status = "ChatGPT 登录成功"
            case .failure(let e): self?.status = "登录失败：\(e)"
            }
        }
    }
    func logout() { KeychainStore.clearChatGPTTokens(); loggedIn = false; status = "已退出登录" }
}

private let accent = LinearGradient(
    colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.27, green: 0.79, blue: 0.96)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

struct SettingsView: View {
    @StateObject private var vm = SettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title
                providerSection
                credentialSection
                modelStyleSection
                triggerSection
                if !vm.status.isEmpty {
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 540)
        .background(
            ZStack {
                Color.black.opacity(0.25)
                Rectangle().fill(.ultraThinMaterial)
            }.ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)
    }

    private var title: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent).frame(width: 26, height: 26)
            Text("知语设置").font(.title2.weight(.semibold))
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型来源")
            Picker("", selection: $vm.kind) {
                ForEach(ProviderKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.kind == .chatGPT {
                sectionHeader("ChatGPT 账号")
                HStack(spacing: 10) {
                    Label(vm.loggedIn ? "已登录" : "未登录",
                          systemImage: vm.loggedIn ? "checkmark.seal.fill" : "person.crop.circle")
                        .foregroundStyle(vm.loggedIn ? .green : .secondary)
                    Spacer()
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.login() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                    if vm.loggedIn { Button("退出") { vm.logout() }.buttonStyle(.bordered) }
                }
            } else {
                sectionHeader("API Key")
                HStack(spacing: 10) {
                    SecureField("粘贴你的 API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                    Button("保存") { vm.saveKey() }.buttonStyle(.borderedProminent).tint(.purple)
                }
            }
        }
    }

    private var modelStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型与风格")
            HStack(spacing: 10) {
                TextField("模型名", text: $vm.model).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                Picker("", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }.labelsHidden().frame(width: 130)
            }
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("触发方式")
            HStack(spacing: 8) {
                Image(systemName: "command")
                Text("在微信里 双击右 ⌘ 唤起候选面板").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
    }
}
```

- [ ] **Step 2: ZhiYuApp 加 settings 窗口场景**

在 `ZhiYu/ZhiYuApp.swift` 的 `body` 里，`Window("知语 · 探针", id: "probe") { ... }` 之后追加：
```swift
        Window("知语设置", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
```

- [ ] **Step 3: 菜单栏加"知语设置…"**

在 `ZhiYu/MenuBar/MenuBarContent.swift` 的 `body` 内（"打开探针窗口"按钮之前）追加：
```swift
        Button("知语设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
```
（`openWindow` 环境已在该文件可用；若未引入则在结构体加 `@Environment(\.openWindow) private var openWindow`。）

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 深色磨砂设置窗口 + 菜单栏入口" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：真机视觉验收（手动）

- [ ] **Step 1: 设置窗口**
⌘R → 菜单栏"知语设置…" → 确认：深色磨砂、分区清晰、Provider 切换/填 key/登录/模型/风格都能用且写入 AppConfig。

- [ ] **Step 2: 候选面板**
微信会话 → 双击右⌘ → 看：深色磨砂卡片、候选弹簧错落入场、悬停高亮发光、底部显示"当前 Provider · 模型"小字、发送按钮。

- [ ] **Step 3: 缓存 bug 复验**
同一会话先用 DeepSeek 生成 → 切到 ChatGPT（设置里切）→ 同会话再生成 → 应**重新调用、不再命中旧候选**（候选应来自新模型）。

> 视觉是迭代的：哪里不够好看/动效太多太少/配色想换，直接说，我调。

## 自检 / Roadmap
- 自检：ZhiYuCore swift test 全绿（含 modelTag）；App BUILD SUCCEEDED。
- 后续：可选聚焦自动触发 + 防抖、按联系人风格、流式候选、多屏精确定位、OCR 兜底、Developer ID 打包分发。
