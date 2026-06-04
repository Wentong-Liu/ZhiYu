# 知语 Phase 10：新消息自动预生成 + 切前台弹出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 或 superpowers:executing-plans 按任务推进。步骤用 `- [ ]`。

**Goal:** 监听微信新消息→后台预生成候选（暖缓存，不弹窗）；当微信切到前台（或新消息来时微信已在前台）→弹出候选面板（缓存命中、秒出）。设置可开关，默认开。

**Architecture:** 事件驱动（AXObserver 监听微信 AX 通知，非轮询）+ NSWorkspace 激活通知。AXObserver 负责"后台预生成"；激活通知负责"切前台才弹"且作为可靠兜底（即使 AX 事件没触发，切前台也会读当前会话、有新消息就生成+弹）。仅当前打开的会话；自己发的/重复同条不触发。

**Tech Stack:** AppKit / ApplicationServices(AXObserver) / NSWorkspace / ZhiYuCore(Swift Testing)。

**关键事实：** `ContextHasher.key` 只含 联系人+消息+草稿（**不含图片**）→ 后台无图预生成的缓存，前台 `present` 同会话能命中。语音/文字新消息后台预暖；图片消息后台不预暖（截图需前台），留给激活时 present 现截现生成。

---

## Part A — ZhiYuCore（TDD）

### Task 1: 会话信号判定（MessageSignal）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/Generation/MessageSignal.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/MessageSignalTests.swift`

- [ ] **Step 1: 失败测试**

```swift
import Testing
@testable import ZhiYuCore

@Suite struct MessageSignalTests {
    private func ctx(_ msgs: [ChatMessage]) -> ChatContext {
        ChatContext(contactName: "x", messages: msgs, draft: "")
    }
    @Test func lastIsIncomingTrueWhenOtherSpokeLast() {
        #expect(MessageSignal.lastIsIncoming(ctx([ChatMessage(speaker: .me, text: "在"), ChatMessage(speaker: .other, text: "你好")])))
    }
    @Test func lastIsIncomingFalseWhenIWroteLast() {
        #expect(!MessageSignal.lastIsIncoming(ctx([ChatMessage(speaker: .other, text: "你好"), ChatMessage(speaker: .me, text: "在")])))
    }
    @Test func lastIsIncomingFalseWhenEmpty() {
        #expect(!MessageSignal.lastIsIncoming(ctx([])))
    }
    @Test func signatureChangesWhenNewMessageArrives() {
        let a = MessageSignal.signature(ctx([ChatMessage(speaker: .other, text: "你好")]))
        let b = MessageSignal.signature(ctx([ChatMessage(speaker: .other, text: "你好"), ChatMessage(speaker: .other, text: "在吗")]))
        #expect(a != b)
    }
    @Test func signatureStableForSameContent() {
        let m = [ChatMessage(speaker: .other, text: "你好")]
        #expect(MessageSignal.signature(ctx(m)) == MessageSignal.signature(ctx(m)))
    }
}
```

- [ ] **Step 2: 跑测试确认红** — `cd ZhiYuCore && swift test --filter MessageSignalTests`（编译失败：MessageSignal 未定义）。

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 判断"是否有等我回的新消息"与"会话指纹（去重/变化检测用）"。纯函数，便于测试。
public enum MessageSignal {
    /// 最后一条是否为对方发来（=轮到我回）。空会话为 false。
    public static func lastIsIncoming(_ ctx: ChatContext) -> Bool {
        ctx.messages.last?.speaker == .other
    }
    /// 会话指纹：消息数 + 最后一条说话人与文本。同一状态稳定、状态变化即变。
    public static func signature(_ ctx: ChatContext) -> String {
        guard let last = ctx.messages.last else { return "empty" }
        return "\(ctx.messages.count)|\(last.speaker.rawValue)|\(last.text)"
    }
}
```
> 注：`ChatMessage.Speaker` 有 `rawValue`（见 ContextHasher 用 `m.speaker.rawValue`）。

- [ ] **Step 4: 跑全量** — `cd ZhiYuCore && swift test` 全绿。
- [ ] **Step 5: 提交** — `git add ZhiYuCore && git commit -m "feat(core): MessageSignal 新消息判定与会话指纹"`

---

## Part B — App

### Task 2: AppConfig 开关

**Files:** Modify `ZhiYu/Config/AppConfig.swift`

- [ ] 加（默认开）：
```swift
    /// 新消息自动预生成候选、切到微信前台时弹出。默认开。
    var autoOnNewMessage: Bool {
        get { d.object(forKey: "autoOnNewMessage") == nil ? true : d.bool(forKey: "autoOnNewMessage") }
        set { d.set(newValue, forKey: "autoOnNewMessage") }
    }
```

### Task 3: CandidatePanelController 复用 present + 自动入口

**Files:** Modify `ZhiYu/Panel/CandidatePanelController.swift`

- [ ] 加字段：`private var lastAutoSignature: String?` 与 `private var lastPrewarmSignature: String?`。
- [ ] 把现有 `trigger()` 抽成"读快照 + present"，并新增 `present(snapshot:)`（内容即原 trigger 体，注意：`dismiss()` 移入 present、并在显示前设 `lastAutoSignature`）：

```swift
    /// 双击触发：读当前会话快照并展示。
    func trigger() {
        guard let snapshot = WeChatReader.readSnapshot() else { NSSound.beep(); return }
        present(snapshot: snapshot)
    }

    /// 用给定快照展示候选面板（手动/自动共用）。
    private func present(snapshot: WeChatReader.Snapshot) {
        guard !snapshot.context.messages.isEmpty, let frame = snapshot.composerFrame else { NSSound.beep(); return }
        dismiss()
        let baseContext = snapshot.context
        let imageFrames = snapshot.imageFrames
        model.isLoading = true
        model.candidates = []
        model.stickerKeyword = nil
        model.status = ""
        model.providerLabel = AppConfig.shared.providerLabel
        lastAutoSignature = MessageSignal.signature(snapshot.context)  // 记录，避免 watcher 重复弹同一条
        showPanel(anchorAXFrame: frame)
        let style = AppConfig.shared.currentStyle()
        Task {
            do {
                let urls = await WeChatReader.captureImages(imageFrames)
                let context = WeChatReader.context(baseContext, withImages: urls)
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: 3, modelTag: AppConfig.shared.modelTag)
                let result = try await gen.generate(context: context, style: style)
                self.model.candidates = result.candidates
                self.model.stickerKeyword = result.stickerKeyword
                self.model.isLoading = false
                if result.candidates.isEmpty && result.stickerKeyword == nil { self.model.status = "模型没有返回候选" }
                self.relayout()
            } catch {
                self.model.isLoading = false
                self.model.status = "失败：\(error)"
                self.relayout()
            }
        }
    }

    /// 微信切到前台：当前会话有等我回的新消息且未处理过 → 展示（缓存暖则秒出）。
    func autoOnActivate() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        guard let snap = WeChatReader.readSnapshot(), !snap.context.messages.isEmpty,
              MessageSignal.lastIsIncoming(snap.context) else { return }
        guard MessageSignal.signature(snap.context) != lastAutoSignature else { return }
        present(snapshot: snap)
    }

    /// AX 事件（防抖后）：有新消息→前台则直接展示，后台则仅预生成暖缓存（图片消息后台不预暖）。
    func autoOnDetect() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        guard let snap = WeChatReader.readSnapshot(), !snap.context.messages.isEmpty,
              MessageSignal.lastIsIncoming(snap.context) else { return }
        guard MessageSignal.signature(snap.context) != lastAutoSignature else { return }
        if isWeChatFrontmost() {
            present(snapshot: snap)
        } else if snap.imageFrames.isEmpty {
            prewarm(snapshot: snap)
        }
    }

    /// 后台仅暖缓存（不弹面板、不设 lastAutoSignature，以便切前台仍会展示）。仅文字/语音（无图）。
    private func prewarm(snapshot: WeChatReader.Snapshot) {
        let sig = MessageSignal.signature(snapshot.context)
        guard sig != lastPrewarmSignature else { return }
        lastPrewarmSignature = sig
        let base = snapshot.context
        let style = AppConfig.shared.currentStyle()
        Task {
            do {
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: 3, modelTag: AppConfig.shared.modelTag)
                _ = try await gen.generate(context: base, style: style)
            } catch { }
        }
    }

    private func isWeChatFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return WeChatAXProbe.bundleIDs.contains(front.bundleIdentifier ?? "")
            || front.localizedName == "WeChat" || front.localizedName == "微信"
    }
```
> 注意：`dismiss()` 原在 `trigger()` 开头，现移入 `present()`，行为不变（每次展示前先收旧面板）。

### Task 4: NewMessageWatcher（AXObserver + 激活监听）

**Files:** Create `ZhiYu/Watch/NewMessageWatcher.swift`

```swift
import AppKit
import ApplicationServices

/// 监听微信新消息（AXObserver，事件驱动非轮询）+ 微信激活（NSWorkspace）。
/// 新消息→防抖→交给 CandidatePanelController 决定预生成/展示；微信激活→展示当前会话的新消息候选（兜底，必然可用）。
@MainActor
final class NewMessageWatcher {
    static let shared = NewMessageWatcher()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var debounce: DispatchWorkItem?
    private var activationToken: NSObjectProtocol?

    func start() {
        if activationToken == nil {
            activationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let isWeChat = WeChatAXProbe.bundleIDs.contains(app.bundleIdentifier ?? "")
                    || app.localizedName == "WeChat" || app.localizedName == "微信"
                guard isWeChat else { return }
                MainActor.assumeIsolated {
                    NewMessageWatcher.shared.registerObserverIfNeeded()   // 跟上当前微信 pid（含微信后启动/重启）
                    CandidatePanelController.shared.autoOnActivate()
                }
            }
        }
        registerObserverIfNeeded()
    }

    /// 注册 AX 观察者到微信 application 元素（app 级通知，切会话无需重注册）。
    func registerObserverIfNeeded() {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return }
        let pid = app.processIdentifier
        if observer != nil, observedPID == pid { return }
        teardown()
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in ["AXCreated", "AXRowCountChanged", "AXValueChanged", "AXLayoutChanged"] {
            AXObserverAddNotification(obs, appEl, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
    }

    private func teardown() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    /// AX 通知回调（已在主线程）：开关关则忽略；否则防抖 0.4s 后交给控制器评估。
    fileprivate func onAXNotification() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { CandidatePanelController.shared.autoOnDetect() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// AXObserver C 回调（无捕获→可转 C 函数指针）。AX 源加在主 runloop，故回调在主线程。
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<NewMessageWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.onAXNotification() }
}
```
- [ ] **构建**：`xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build` 必须成功（修正 AX 常量/签名偏差；若 `"AXCreated"` 等字面量不被接受，改用 `kAXCreatedNotification as CFString` 等常量）。

### Task 5: 启动 watcher + 设置开关

**Files:** Modify `ZhiYu/AppDelegate.swift`、`ZhiYu/Settings/SettingsView.swift`

- [ ] AppDelegate `applicationDidFinishLaunching`（在 `doubleTap.start()` 之后、`isDuplicate` 早退之后）加：
```swift
        NewMessageWatcher.shared.start()
```
- [ ] SettingsView：按现有布尔项的样式，加一个开关，绑定到 `autoOnNewMessage`（用与其它设置一致的方式；若用 `@AppStorage` 则 `@AppStorage("autoOnNewMessage") var autoOnNewMessage = true`）。文案：
  `Toggle("新消息自动生成候选（切到微信前台时弹出）", isOn: $autoOnNewMessage)`，并配一行说明小字"对方发来新消息时后台预生成；切到微信前台时弹出候选。"
- [ ] **构建**：`xcodebuild ... build` 成功；跑完 `rm -rf build ZhiYuCore/build`。
- [ ] **提交**：`git add ZhiYu && git commit -m "feat(app): 新消息自动预生成+切微信前台弹出（AXObserver+激活监听+设置开关）"`

### Task 6: 真机联调（人工）
开 设置开关 → 让对方/另一设备给当前会话发条消息 → 观察：①微信在后台时不弹、切回微信即弹且候选已就绪（秒出）；②微信在前台时来消息直接弹；③自己发的不触发；④同一条不重复弹；⑤关掉开关后不再自动弹。

---

## Self-Review
- 覆盖：监听(Task4)、后台预生成/前台弹出/兜底(Task3)、判定(Task1)、开关(Task2/5)、联调(Task6)。✅
- 类型一致：`present(snapshot:)`/`autoOnDetect`/`autoOnActivate`/`prewarm` 共用 model 与 cache；`lastAutoSignature`(展示去重) 与 `lastPrewarmSignature`(预暖去重) 分开。✅
- 缓存：ContextHasher 不含图片→无图预暖可被前台命中；图片消息后台跳过预暖。✅
- 并发：AXObserver 回调与 NSWorkspace 块均在主线程，`MainActor.assumeIsolated` 跳到主 actor；C 回调无捕获。✅
- 风险：AX 通知可能偏吵→防抖 0.4s + 控制器侧 signature 去重；即便 AX 没触发，激活兜底保证可用。
