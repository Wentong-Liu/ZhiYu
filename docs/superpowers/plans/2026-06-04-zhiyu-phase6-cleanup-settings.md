# 知语 ZhiYu — Phase 6：去探针窗口 + 自定义提示词 + 模型下拉 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ① 移除开发态探针窗口（产品化收尾）；② 设置支持"自定义提示词"风格（自由文本，覆盖预设）；③ 模型名从手填改为**按 Provider 的下拉选项**（OpenAI: GPT-5.5/5.4/5.3/4o；DeepSeek: Flash/Pro；ChatGPT 登录: gpt-5.5/5.5-pro/5.4/5.4-pro/5.4-mini）。

**Architecture:** 纯 App 侧改动（删窗口/场景/菜单项 + AppConfig 扩展 + SettingsView 重构）。`WeChatAXProbe`/`InserterProbe` 是生产 AX 引擎，保留。`xcodebuild` 验证 + 手动看效果。

**Tech Stack:** Swift 6.3 / SwiftUI。分支 **main**（直接提交）。

**前置：** Phase 1-5 完成。当前有 `ZhiYu/Probe/ProbeView.swift`(开发窗口)、`ZhiYu/Generate/GeneratePanel.swift`(开发生成面板)、`ZhiYu/Probe/GlobalHotkey.swift`(旧 ⌥⌘R，已被 RightCommandDoubleTap 取代)、`ZhiYu/Settings/SettingsView.swift`、`ZhiYu/Config/AppConfig.swift`、`ZhiYu/Panel/CandidatePanelController.swift`、`ZhiYu/ZhiYuApp.swift`、`ZhiYu/MenuBar/MenuBarContent.swift`。`ReplyStyle.custom(_:)` 已在 ZhiYuCore。

---

## Task 1：移除探针窗口

**Files:**
- Delete: `ZhiYu/Probe/ProbeView.swift`、`ZhiYu/Generate/GeneratePanel.swift`、`ZhiYu/Probe/GlobalHotkey.swift`
- Modify: `ZhiYu/ZhiYuApp.swift`、`ZhiYu/MenuBar/MenuBarContent.swift`

> 保留 `ZhiYu/Probe/WeChatAXProbe.swift` 与 `ZhiYu/Probe/InserterProbe.swift`（生产 AX 引擎）。

- [ ] **Step 1: 删除 3 个开发态文件**

Run:
```bash
git rm ZhiYu/Probe/ProbeView.swift ZhiYu/Generate/GeneratePanel.swift ZhiYu/Probe/GlobalHotkey.swift
```

- [ ] **Step 2: ZhiYuApp 去掉探针 Window 场景**

`ZhiYu/ZhiYuApp.swift`（整文件替换）:
```swift
import SwiftUI

@main
struct ZhiYuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("知语", systemImage: "bubble.left.and.bubble.right") {
            MenuBarContent()
        }
        Window("知语设置", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
```

- [ ] **Step 3: 菜单栏去掉"打开探针窗口"**

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
        Button("知语设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（若报某符号未定义，说明还有对 ProbeView/GeneratePanel/GlobalHotkey 的引用残留，按报错清理）。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor(app): 移除开发态探针窗口，仅留菜单栏+设置窗口" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：AppConfig 扩展（每 Provider 模型选项 + 自定义提示词 + currentStyle）

**Files:**
- Modify: `ZhiYu/Config/AppConfig.swift`
- Modify: `ZhiYu/Panel/CandidatePanelController.swift`

- [ ] **Step 1: ProviderKind 加模型选项 + 默认模型；AppConfig 加 customPrompt + currentStyle**

在 `ZhiYu/Config/AppConfig.swift`：

给 `ProviderKind` 加（在 enum 内）:
```swift
    /// 该 Provider 可选模型：(id 发给 API, label 展示)。
    var modelOptions: [(id: String, label: String)] {
        switch self {
        case .openAI:
            return [("gpt-5.5", "GPT-5.5"), ("gpt-5.4", "GPT-5.4"),
                    ("gpt-5.3", "GPT-5.3"), ("gpt-4o", "GPT-4o")]
        case .deepSeek:
            return [("deepseek-v4-flash", "Flash"), ("deepseek-v4-pro", "Pro")]
        case .chatGPT:
            return [("gpt-5.5", "GPT-5.5"), ("gpt-5.5-pro", "GPT-5.5 Pro"),
                    ("gpt-5.4", "GPT-5.4"), ("gpt-5.4-pro", "GPT-5.4 Pro"),
                    ("gpt-5.4-mini", "GPT-5.4 mini")]
        }
    }
    var defaultModel: String { modelOptions.first?.id ?? "" }
```

给 `AppConfig` 加:
```swift
    /// 自定义提示词（风格选"自定义"时用）。
    var customPrompt: String {
        get { d.string(forKey: "customPrompt") ?? "" }
        set { d.set(newValue, forKey: "customPrompt") }
    }

    /// 当前风格：styleIndex 落在预设范围内取预设，否则取自定义提示词。
    func currentStyle() -> ReplyStyle {
        let presets = ReplyStyle.presets
        if styleIndex >= presets.count {
            let p = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplyStyle.custom(p.isEmpty ? "用自然、得体、口语化的语气回复。" : p)
        }
        return presets[max(0, min(styleIndex, presets.count - 1))]
    }
```
（`AppConfig.swift` 顶部若未 `import ZhiYuCore` 则加上，以用 `ReplyStyle`。）

- [ ] **Step 2: CandidatePanelController 用 currentStyle()**

在 `ZhiYu/Panel/CandidatePanelController.swift` 的 `trigger()` 里，把原来取 style 的那行
`let style = ReplyStyle.presets[min(AppConfig.shared.styleIndex, ReplyStyle.presets.count - 1)]`
改为：
```swift
        let style = AppConfig.shared.currentStyle()
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): AppConfig 加每Provider模型选项 + 自定义提示词 + currentStyle" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：设置窗口——模型下拉 + 风格含"自定义"提示词

**Files:**
- Modify: `ZhiYu/Settings/SettingsView.swift`

- [ ] **Step 1: SettingsModel 加 customPrompt；syncForKind 用 defaultModel**

在 `SettingsModel`：
1. 加属性（与其它 @Published 并列）:
```swift
    @Published var customPrompt: String { didSet { AppConfig.shared.customPrompt = customPrompt } }
```
2. `init()` 末尾（`switch` 之后）加：`customPrompt = AppConfig.shared.customPrompt`。注意 init 里给 `customPrompt` 赋值需在所有 stored 属性初始化之后；因 `customPrompt` 有 didSet，init 内赋值不会触发 didSet（Swift 语义），安全。
3. `syncForKind()` 整体替换为按默认模型：
```swift
    func syncForKind() {
        switch kind {
        case .openAI: apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .chatGPT: break
        }
        model = kind.defaultModel
    }
```

- [ ] **Step 2: modelStyleSection 改为模型下拉 + 风格下拉(+自定义) + 自定义文本框**

把 `SettingsView` 的 `modelStyleSection` 整段替换为：
```swift
    private var modelStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型与风格")
            HStack(spacing: 10) {
                Picker("", selection: $vm.model) {
                    ForEach(vm.kind.modelOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .labelsHidden().tint(.white).frame(maxWidth: .infinity)

                Picker("", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in
                        Text(s.name).tag(i)
                    }
                    Text("自定义").tag(vm.styles.count)
                }
                .labelsHidden().tint(.white).frame(width: 130)
            }
            if vm.styleIndex >= vm.styles.count {
                TextEditor(text: $vm.customPrompt)
                    .font(.callout)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.1)))
                    .overlay(alignment: .topLeading) {
                        if vm.customPrompt.isEmpty {
                            Text("写给大模型的提示词，例如：用我一贯的简短、略带调侃的口吻回复，多用语气词。")
                                .font(.callout).foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                        }
                    }
            }
        }
    }
```

> 说明：模型 Picker 的 `selection` 绑定 `$vm.model`（String id）；切换 Provider 时 `syncForKind` 已把 `model` 设为该 Provider 的 `defaultModel`（即第一项），保证选中项合法。风格 Picker 末尾多一个 tag 为 `styles.count` 的"自定义"项，选中后展示 TextEditor 编辑 `customPrompt`。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 设置窗口模型下拉(按Provider) + 自定义提示词" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：手动验收

- [ ] **Step 1: 探针窗口已消失**
⌘R → 菜单栏只剩"辅助功能 / 知语设置… / 退出知语"，无"打开探针窗口"；双击右⌘ 仍能唤起候选面板。

- [ ] **Step 2: 模型下拉**
设置窗口 → 切 OpenAI 看到 GPT-5.5/5.4/5.3/4o；切 DeepSeek 看到 Flash/Pro；切 ChatGPT 登录看到 gpt-5.5/5.5-pro/5.4/... 切换 Provider 时模型自动落到第一项。

- [ ] **Step 3: 自定义提示词**
风格选"自定义" → 出现文本框 → 写一段提示词 → 微信会话双击右⌘ 生成 → 候选应体现你的自定义口吻。预设风格仍正常。

> 想再调：模型选项增删、自定义框默认占位文案、布局，直接说。

## 自检 / Roadmap
- 自检：App BUILD SUCCEEDED；探针窗口引用清理干净；模型/风格/自定义都落 AppConfig。
- 后续：可选聚焦自动触发、按联系人风格、流式候选、Developer ID 打包分发。
