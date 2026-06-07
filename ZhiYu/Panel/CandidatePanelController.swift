import AppKit
import SwiftUI
import ZhiYuCore

/// 管理候选悬浮面板：双击触发后 读会话 -> 定位 -> 生成 -> 展示 -> 填入/发送 -> 消失。
@MainActor
final class CandidatePanelController: NSObject {
    static let shared = CandidatePanelController()

    /// ESC 键的两种比对口径（同源，避免散落三处魔法值）：
    /// - NSEvent.charactersIgnoringModifiers 比对字符；CGEventTap 比对硬件键码。
    /// 风格对齐 InserterProbe.keyCodeReturn=36。
    private enum KeyCode {
        /// ESC 的硬件键码（CGEventTap 用）。
        static let escape: Int64 = 53
        /// ESC 的字符（NSEvent 监听用，charactersIgnoringModifiers 比对）。
        static let escapeChar = "\u{1B}"
    }

    /// 面板布局常量。
    private enum Layout {
        /// 面板底边与 composer 顶边的间隙。
        static let gap: CGFloat = 8
        /// 面板可用高度下限（屏太矮时的兜底）。
        static let minHeight: CGFloat = 220
        /// 面板高度相对屏 visibleFrame 上下留白。
        static let screenMargin: CGFloat = 24
        /// 取不到屏 visibleFrame 时的兜底矩形。
        static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        /// 取不到主屏高度时的兜底（AX↔AppKit 全局 y 翻转基准）。
        static let fallbackPrimaryHeight: CGFloat = 1000
        /// 新建 NSPanel 时的初始高度（建后即按内容 relayout）。
        static let initialPanelHeight: CGFloat = 120
    }

    /// 用户拖动后记录的"相对自动锚点的偏移"（跟随微信窗口：自动锚点实时算，叠加此偏移即最终位置）。
    /// 持久化到 UserDefaults（存 [Double] 两元素）；双击把手或缺省为 .zero（退回纯自动定位）。
    private static let manualOffsetKey = "ZhiYu.panelManualOffset"
    private var manualOffset: CGSize

    /// 上次成功展示时的 composer AX 锚点（持久化到 UserDefaults，存 [minX, minY, width, height]）。
    /// 让"先弹后读"在每次启动后的第一次 trigger 也能立即弹；仅全新安装从未弹过时为 .zero（走同步兜底）。
    private static let anchorKey = "ZhiYu.lastAnchorAXFrame"

    private var panel: NSPanel?
    private var anchorAXFrame: CGRect = .zero
    private let model = CandidatePanelModel()
    private let cache = CandidateCache()
    private var keyMonitor: Any?
    private var escGlobalMonitor: Any?
    private var escEventTap: CFMachPort?
    private var escRunLoopSource: CFRunLoopSource?

    /// 按联系人记的"已展示/已建基线"会话指纹：只有当前打开会话的指纹相对基线变化、且最后一条是对方发的，
    /// 才算新消息。避免"联系人 A 来消息但当前开着 B"时误把 B 当新消息弹出来。
    private var lastSeenSig: [String: String] = [:]
    /// 按联系人记的"已预暖"会话指纹（预暖去重）。
    private var lastPrewarmSig: [String: String] = [:]
    /// 上次廉价指纹（高频去重前移：相同则不跑昂贵的完整快读）。
    private var lastCheapSignature: String?
    /// 一次 present 的 Task 是否在飞：转文字会改动微信 AX→触发 watcher，须在此期间抑制自动评估的 re-entry，避免重复弹。
    private var isBusy = false
    /// 忙碌期到达的新消息标记：忙碌时不消费 lastCheapSignature（否则会被永久去重丢弃），仅置位；忙碌结束补跑评估。
    private var pendingRecheck = false
    /// present 代际令牌：新 present 取代在飞旧 present 时自增，旧 Task 完成时凭此识别自己已陈旧、不再写回。
    private var presentGeneration = 0
    /// 当前在飞的 present 任务：ESC/dismiss 时取消，让转写循环立即停、不再 AXShowMenu/把微信拉前台。
    private var currentTask: Task<Void, Never>?
    /// 本次面板所针对的会话联系人：落地动作（填入/发送/发表情）前据此校验微信当前会话是否仍一致，避免发错会话。
    /// dismiss 不清此字段，故 onSendSticker 先 dismiss 后仍能判。
    private var presentTargetContact: String?

    override init() {
        // 从 UserDefaults 读上次拖动后的手动偏移（[Δx, Δy]）；缺省/格式不符则回退 .zero（纯自动定位）。
        if let arr = UserDefaults.standard.array(forKey: Self.manualOffsetKey) as? [Double], arr.count == 2 {
            manualOffset = CGSize(width: arr[0], height: arr[1])
        } else {
            manualOffset = .zero
        }
        super.init()
        // 读上次成功展示的 composer AX 锚点（[minX, minY, width, height]）：让启动后第一次 trigger 也能"先弹后读"。
        if let arr = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], arr.count == 4 {
            anchorAXFrame = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
    }

    /// 双击触发：复用记住的面板位置立即弹加载面板，再在下一个 runloop 异步读会话→读回来只出候选不重定位→生成（先弹后读，消除可感延迟与跳动）。
    func trigger() {
        // 未授予辅助功能权限时：仅弹系统授权提示（其自带"打开系统设置"按钮，用户点了才开），不再自动打开系统设置，不静默 beep。
        guard AccessibilityAuthorizer.isTrusted else {
            AccessibilityAuthorizer.promptIfNeeded()
            return
        }
        // 本机从未成功弹过、无可用锚点：退回"先读后弹"仅此一次（读到的 composer frame 即成首个锚点）。
        guard anchorAXFrame != .zero else {
            guard let snap = WeChatReader.readSnapshot(), !snap.context.messages.isEmpty, snap.composerFrame != nil else { NSSound.beep(); return }
            present(snapshot: snap)
            return
        }
        // 先用上次锚点立即弹出加载面板，再异步读会话。
        let generation = beginPresentation(anchor: anchorAXFrame)
        // 关键：阻塞式 readSnapshot（~200ms 同步 AX 读）放到后台线程跑，腾空主 run loop——
        // 这样加载面板能在读之前先绘制（"立即弹出"），且读进行中按 ESC 时，ESC 的 CGEventTap 回调
        // 不再排在同步读之后，可立即触发 dismiss()，面板秒关。Task 在 @MainActor 类里继承 @MainActor，
        // 故 await 之后回到主线程，访问 self 状态安全。
        Task { [weak self] in
            #if DEBUG
            let t0 = Date()
            #endif
            let snap = await Task.detached { WeChatReader.readSnapshot() }.value  // 读会话在后台线程
            guard let self else { return }
            // 期间已 ESC/dismiss(panel=nil) 或被新 present 取代 → 丢弃，绝不在已关闭/已被取代的面板上继续。
            guard generation == self.presentGeneration, self.panel != nil else { return }
            #if DEBUG
            NSLog("[ZhiYu] trigger readSnapshot %.0fms", Date().timeIntervalSince(t0) * 1000)
            #endif
            guard let snap, !snap.context.messages.isEmpty else { self.dismiss(); NSSound.beep(); return }
            // 复用记住的位置：读回来只用于出候选，不重定位面板（避免跳动）。位置由首次读取确立、之后靠手动拖动调整。
            self.lastSeenSig[snap.context.contactName] = MessageSignal.signature(snap.context)
            self.presentTargetContact = snap.context.contactName  // 记本次面板的目标会话，供落地动作校验
            self.runGeneration(baseContext: snap.context, imageFrames: snap.imageFrames, style: AppConfig.shared.currentStyle(), generation: generation)
        }
    }

    /// 用给定快照展示候选面板（自动路径继续用）：薄封装，行为与改动前等价。
    private func present(snapshot: WeChatReader.Snapshot) {
        guard !snapshot.context.messages.isEmpty, let frame = snapshot.composerFrame else { NSSound.beep(); return }
        let g = beginPresentation(anchor: frame)
        persistAnchor(frame)
        lastSeenSig[snapshot.context.contactName] = MessageSignal.signature(snapshot.context)  // 标记已展示
        presentTargetContact = snapshot.context.contactName  // 记本次面板的目标会话，供落地动作校验
        runGeneration(baseContext: snapshot.context, imageFrames: snapshot.imageFrames, style: AppConfig.shared.currentStyle(), generation: g)
    }

    /// present 的公共起手：收残留→进 busy→自增代际→复位 model 到加载态→用给定锚点建面板→取消在飞旧任务。
    /// 返回自增后的 presentGeneration（generation token），供后续异步读会话/生成时识别陈旧。
    private func beginPresentation(anchor: CGRect) -> Int {
        dismiss()  // 重复展示前先收掉残留面板/监听，避免层叠
        isBusy = true
        presentGeneration += 1
        // 先复位到加载态再建面板：面板按"加载态"测高，内容到位后再 relayout，避免沿用上次内容的尺寸。
        model.isLoading = true
        model.loadingNote = "生成中…"
        model.candidates = []
        model.stickerKeyword = nil
        model.status = ""
        model.providerLabel = AppConfig.shared.providerLabel
        showPanel(anchorAXFrame: anchor)
        currentTask?.cancel()  // 取代在飞的旧任务（其转写循环会响应取消立即停）
        return presentGeneration
    }

    /// 在飞的生成任务：语音转写→截图→生成→写回 model→relayout→复位 isBusy（含陈旧判定与错误文案）。
    private func runGeneration(baseContext: ChatContext, imageFrames: [CGRect], style: ReplyStyle, generation: Int) {
        var baseContext = baseContext
        var imageFrames = imageFrames
        let baseContact = baseContext.contactName  // 转写等待期间用户可能切会话：重读后据此校验，避免串会话
        currentTask = Task {
            do {
                // 若会话里有"未转文字"的语音 → 取最近 5 条触发转写并等到完成，转写回来后重读。
                // transcribeRecentAndWait 已等到转写落地，故重读拿到的是转写后的文本，generate 不会用 [语音] 占位。
                if baseContext.messages.contains(where: { $0.text.contains(WeChatMarkers.voicePlaceholder) }) {
                    if generation == self.presentGeneration { self.model.loadingNote = "转写语音中…" }
                    await VoiceTranscriber.transcribeRecentAndWait(target: baseContact)
                    if Task.isCancelled { return }  // ESC 已取消：不再重读/生成
                    if let fresh = WeChatReader.readSnapshot() {
                        // 转写等待期间用户切到了别的会话：放弃本次（用旧上下文生成会发错会话），收掉面板。
                        guard fresh.context.contactName == baseContact else {
                            if generation == self.presentGeneration { self.dismiss() }
                            return
                        }
                        baseContext = fresh.context
                        imageFrames = fresh.imageFrames
                        if generation == self.presentGeneration {
                            self.lastSeenSig[baseContext.contactName] = MessageSignal.signature(baseContext)
                        }
                    }
                    if generation == self.presentGeneration { self.model.loadingNote = "生成中…" }
                }
                // 异步截取图片/表情气泡，附到上下文后再生成。无图时 urls 为空、上下文仅文本。
                let urls = await WeChatReader.captureImages(imageFrames)
                let context = WeChatReader.context(baseContext, withImages: urls)
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: ReplyGenerator.defaultCandidateCount, modelTag: AppConfig.shared.modelTag)
                let result = try await gen.generate(context: context, style: style)
                guard generation == self.presentGeneration else { return }  // 陈旧任务：新 present 已接管，不写、不动 isBusy
                self.model.candidates = result.candidates
                self.model.stickerKeyword = result.stickerKeyword
                self.model.isLoading = false
                if result.candidates.isEmpty && result.stickerKeyword == nil { self.model.status = "模型没有返回候选" }
                self.relayout()  // 内容到位后按真实高度重新布局
                self.isBusy = false
                self.drainPendingRecheck()  // 忙碌期到过新消息则补跑评估
            } catch {
                guard generation == self.presentGeneration else { return }  // 陈旧任务：新 present 已接管，不写、不动 isBusy
                self.model.isLoading = false
                // UI 文案：对网络/鉴权/解析做简洁中文映射；完整 error 仅 NSLog 便于诊断（控制流不变）。
                NSLog("[ZhiYu] 生成失败 error=%@", String(describing: error))
                self.model.status = Self.userFacingMessage(for: error)
                self.relayout()
                self.isBusy = false
                self.drainPendingRecheck()  // 忙碌期到过新消息则补跑评估
            }
        }
    }

    /// 微信切到前台：评估当前打开会话是否有新的对方消息 → 展示（缓存暖则秒出）。
    func autoOnActivate() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        evaluateAuto(canPresent: true)
    }

    /// AX 事件（防抖+硬节流后）：先做极廉价的预判（只读消息表行数+最后一行文本）抑制前台狂刷的昂贵快读，
    /// 再评估当前打开会话。
    func autoOnDetect() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        if let cheap = WeChatAXProbe.cheapSignature() {
            guard cheap != lastCheapSignature else { return }
            // 忙碌期绝不写 lastCheapSignature（否则这条新指纹被消费却没处理，之后被去重永久丢）：仅置位，忙碌结束补跑。
            if isBusy { pendingRecheck = true; return }
            lastCheapSignature = cheap
        }
        evaluateAuto(canPresent: isWeChatFrontmost())
    }

    /// 忙碌结束补跑：忙碌期到过新消息（pendingRecheck）则复位标记并重新评估当前会话。
    /// 仅在非忙碌时 drain；忙碌则保留标记待下次（延后的 drain 可能赶上新一轮 isBusy=true，
    /// 此时若清掉标记会让这次忙碌期的新消息补跑丢失，故忙碌时直接返回、不清标记，留到下次 isBusy 转 false 再 drain）。
    private func drainPendingRecheck() {
        guard pendingRecheck, !isBusy else { return }
        pendingRecheck = false
        evaluateAuto(canPresent: isWeChatFrontmost())
    }

    /// 统一评估当前"打开的会话"是否出现了新的对方消息。
    /// 按联系人记基线：首次见到该会话只建基线不触发；只有指纹相对基线变化、且最后一条是对方发的才算新消息。
    /// 这样"A 来消息但当前开着 B"时不会误弹 B（B 没变化）。
    private func evaluateAuto(canPresent: Bool) {
        guard !isBusy else { return }
        guard let snap = WeChatReader.readSnapshot(), !snap.context.messages.isEmpty else { return }
        let ctx = snap.context
        let contact = ctx.contactName
        let sig = MessageSignal.signature(ctx)
        guard let baseline = lastSeenSig[contact] else {
            lastSeenSig[contact] = sig   // 首次见到该会话：建基线，不触发
            return
        }
        guard sig != baseline else { return }                 // 该会话没变化
        guard MessageSignal.lastIsIncoming(ctx) else {         // 变了但最后一条不是对方（我发的/系统）：更新基线，不触发
            lastSeenSig[contact] = sig; return
        }
        // 当前打开会话出现了新的、未展示过的对方消息
        let typing = !ctx.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if canPresent && !typing && snap.composerFrame != nil {
            present(snapshot: snap)                            // present 内会更新 lastSeenSig
        } else if snap.imageFrames.isEmpty {
            prewarm(snapshot: snap)                            // 后台/正在打字：仅预暖，不更新基线（切前台仍会展示）
        }
    }

    /// 后台仅暖缓存（不弹面板、不更新 lastSeenSig，以便切前台仍会展示）。
    /// 含未转语音的会话直接跳过：后台转写会触发 app.activate 抢焦点，语音的转写只在前台 present() 里做。
    private func prewarm(snapshot: WeChatReader.Snapshot) {
        let ctx = snapshot.context
        guard !ctx.messages.contains(where: { $0.text.contains(WeChatMarkers.voicePlaceholder) }) else { return }  // 含未转语音的会话不在后台预暖（避免转写抢焦点）
        let sig = MessageSignal.signature(ctx)                // dedup 用进入时原始 ctx 的指纹作键（同一触发不重复预暖）
        guard lastPrewarmSig[ctx.contactName] != sig else { return }
        let style = AppConfig.shared.currentStyle()
        Task {
            do {
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: ReplyGenerator.defaultCandidateCount, modelTag: AppConfig.shared.modelTag)
                _ = try await gen.generate(context: ctx, style: style)
                self.lastPrewarmSig[ctx.contactName] = sig   // 成功后才记指纹；失败留待重试
            } catch {
                // 后台预暖失败：吞掉不打扰用户（不弹面板），但记日志便于诊断（含联系人+错误）。
                NSLog("[ZhiYu] prewarm 失败 contact=%@ error=%@", ctx.contactName, String(describing: error))
            }
        }
    }

    private func isWeChatFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return WeChatAXProbe.isWeChat(front)
    }

    /// 落地动作前校验微信「当前打开会话」是否仍是本次面板的目标会话。
    /// 务必默认放行、绝不误拦：无目标/读不到/为空一律放行（return true），只在确读到不同会话才返回 false。
    private func guardSameConversation() -> Bool {
        return WeChatAXProbe.isCurrentContact(presentTargetContact)
    }

    private func showPanel(anchorAXFrame axFrame: CGRect) {
        self.anchorAXFrame = axFrame
        model.onFill = { [weak self] t in guard let self else { return }; if self.guardSameConversation() { Inserter.fill(t) } else { NSSound.beep() }; self.dismiss() }
        model.onSend = { [weak self] t in guard let self else { return }; if self.guardSameConversation() { Inserter.sendSequential(BubbleSplitter.split(t), targetContact: self.presentTargetContact) } else { NSSound.beep() }; self.dismiss() }
        model.onSendSticker = { [weak self] kw in guard let self else { return }; self.dismiss(); if self.guardSameConversation() { StickerSender.send(keyword: kw, targetContact: self.presentTargetContact) } else { NSSound.beep() } }
        model.onDismiss = { [weak self] in self?.dismiss() }
        // 拖动松手：把面板当前原点相对实时自动锚点的差值记为手动偏移并持久化（跟随微信窗口）。
        model.onDragMoved = { [weak self] in
            guard let self, let p = self.panel else { return }
            let base = self.autoOrigin()
            self.manualOffset = CGSize(width: p.frame.origin.x - base.x, height: p.frame.origin.y - base.y)
            self.saveManualOffset()
        }
        // 双击把手：清零偏移并立即重定位回自动锚点。
        model.onDragReset = { [weak self] in
            guard let self else { return }
            self.manualOffset = .zero
            self.saveManualOffset()
            self.relayout()
        }

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CandidatePanelView.baseWidth, height: Layout.initialPanelHeight),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.contentView = NSHostingView(rootView: CandidatePanelView(model: model, scrollable: false, maxHeight: .greatestFiniteMagnitude))
        self.panel = p
        relayout()
        p.orderFrontRegardless()

        installKeyMonitor()
    }

    /// 按当前 model 内容重新测高、调整面板尺寸与位置（内容到位后调用）。
    /// 透明外边距 shadowPad 计入窗口尺寸，并从 gap/x 里扣除，故卡片视觉位置不变。
    private func relayout() {
        guard let panel = self.panel else { return }
        let axFrame = self.anchorAXFrame
        let pad = CandidatePanelView.shadowPad

        let screen = screenContaining(axPointTopLeft: CGPoint(x: axFrame.midX, y: axFrame.minY))
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? Layout.fallbackVisibleFrame
        let available = max(Layout.minHeight, vf.height - Layout.screenMargin)

        // 测自然高度（含 2*pad 外边距）。
        let measure = NSHostingView(rootView: CandidatePanelView(model: model, scrollable: false, maxHeight: .greatestFiniteMagnitude))
        measure.layout()
        let natural = measure.fittingSize
        let width = max(natural.width, CandidatePanelView.baseWidth + 2 * pad)
        let needScroll = natural.height > available
        let panelH = min(natural.height, available)

        // 滚动态下，卡片的 maxHeight 应扣除上下外边距。
        if let host = panel.contentView as? NSHostingView<CandidatePanelView> {
            host.rootView = CandidatePanelView(model: model, scrollable: needScroll, maxHeight: panelH - 2 * pad)
        }
        panel.setContentSize(NSSize(width: width, height: panelH))

        // 自动锚点叠加手动偏移后由 PanelPositioning.clamped 单次夹紧进可见区。manualOffset 为 .zero 时退化为纯自动锚点。
        let origin = PanelPositioning.clamped(origin: autoOrigin(), offset: manualOffset,
                                              size: CGSize(width: width, height: panelH), within: vf)
        panel.setFrameOrigin(origin)
    }

    /// 未夹紧的自动锚点（AppKit 全局左下原点）：AX->AppKit 全局 y 翻转（基于主屏高度），
    /// 外边距 pad 从 gap/x 扣除以保持卡片视觉位置。不依赖面板 width/height，故 dragMoved 里也能算同一基准。
    private func autoOrigin() -> CGPoint {
        let pad = CandidatePanelView.shadowPad
        var origin = PanelPositioning.panelOrigin(composerAXFrame: anchorAXFrame,
                                                  primaryScreenHeight: Self.primaryScreenHeight, gap: Layout.gap - pad)
        origin.x -= pad
        return origin
    }

    /// 持久化手动偏移到 UserDefaults（[Δx, Δy]）。
    private func saveManualOffset() {
        UserDefaults.standard.set([Double(manualOffset.width), Double(manualOffset.height)], forKey: Self.manualOffsetKey)
    }

    /// 持久化 composer AX 锚点到 UserDefaults（[minX, minY, width, height]）：供启动后第一次 trigger 立即弹。
    private func persistAnchor(_ f: CGRect) {
        UserDefaults.standard.set([Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)], forKey: Self.anchorKey)
    }

    /// 面板存活期间的键盘处理（ESC 三路收敛，职责互斥）：
    /// - 本地监听(local)：管 1/2/3 数字键选中，并在 tap 兜底失败时也能在面板为 key 时关闭(Esc)。始终注册。
    /// - CGEventTap：ESC 关闭的主路——装上后独占消费 ESC（吞掉事件、无系统蜂鸣）。
    /// - 全局监听(global)：仅在 tap 创建失败时才注册，作为真正的兜底关闭（只观察不吞、仍有蜂鸣）；
    ///   tap 装上时不再注册它（否则它的 ESC 分支永远收不到被 tap 吞掉的事件，是冗余 no-op）。
    /// 不再监听"外部点击消失"——别的 app 弹窗点击会误关面板。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            // 数字键选中：1...候选数 内的数字键填入对应候选（上限与生成数同源）。
            if let n = Int(chars), n >= 1, n <= ReplyGenerator.defaultCandidateCount {
                if n - 1 < self.model.candidates.count {
                    self.model.onFill(self.model.candidates[n - 1])
                }
                return nil
            }
            if chars == KeyCode.escapeChar { // Esc
                self.dismiss(); return nil
            }
            return event
        }
        // tap 为主：装上即由它消费 ESC；仅当 tap 创建失败时才挂 global ESC 监听作真正兜底。
        if !installEscEventTap() {
            escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel != nil else { return }
                if (event.charactersIgnoringModifiers ?? "") == KeyCode.escapeChar { self.dismiss() }
            }
        }
    }

    /// 面板存活期临时装一个 CGEventTap 拦截 keyDown：仅 ESC(KeyCode.escape) 时 dismiss() 并吞掉事件
    /// （面板 .nonactivatingPanel/不抢焦点，ESC 实际仍发给微信→系统蜂鸣，故需在这里吞掉）。
    /// 其余事件一律原样放行（含回车 keyCode 36，发送不受影响）；创建失败时回退到 global NSEvent 监听（仅能关面板、仍有蜂鸣）。
    /// 返回 tap 是否成功装上：装上则由它独占处理 ESC（消费/无蜂鸣），调用方据此决定是否再挂 global 兜底。
    @discardableResult
    private func installEscEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // tap 被系统因超时/用户输入禁用时重新启用
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon {
                    let ctrl = Unmanaged<CandidatePanelController>.fromOpaque(refcon).takeUnretainedValue()
                    if let tap = ctrl.escEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == KeyCode.escape {  // ESC
                if let refcon {
                    let ctrl = Unmanaged<CandidatePanelController>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { ctrl.dismiss() }
                }
                return nil  // 吞掉 ESC：不发给微信、无蜂鸣
            }
            return Unmanaged.passUnretained(event)  // 其余按键/事件一律原样放行（含回车 keyCode 36，发送不受影响）
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: refcon) else {
            NSLog("[ZhiYu] ESC CGEventTap 创建失败，回退到 global monitor（关闭面板仍可、但有蜂鸣）"); return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        escEventTap = tap; escRunLoopSource = src
        return true
    }

    func dismiss() {
        currentTask?.cancel(); currentTask = nil  // 取消在飞转写/生成，转写循环立即停、不再 AXShowMenu/拉前台
        isBusy = false                            // 取消后不要卡在 busy，否则自动评估会被一直抑制
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }
        // 彻底拆除 ESC CGEventTap，避免面板关后仍全局拦键
        if let src = escRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes); escRunLoopSource = nil }
        if let tap = escEventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); escEventTap = nil }
        panel?.close()
        panel = nil
        // 延后补跑评估到下一轮 run loop：让 panel?.close() 先生效、视觉先刷新（ESC 后面板即时关），
        // 补跑的会话评估（可能再触发昂贵读取）放到下一轮，不阻塞本次关闭的视觉响应。
        DispatchQueue.main.async { [weak self] in self?.drainPendingRecheck() }
    }

    /// 主显示器（含 AppKit 全局原点、frame.origin == (0,0) 的屏）的高度；AX/CG 全局 y 翻转的基准。
    /// AX 与 AppKit 共享全局平面、原点都锚在主屏，故用主屏高度做 `appKitY = h - axY` 的全局换算。
    private static var primaryScreenHeight: CGFloat {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        return primary?.frame.height ?? Layout.fallbackPrimaryHeight
    }

    private func screenContaining(axPointTopLeft p: CGPoint) -> NSScreen? {
        // AX 点为左上原点、全局坐标（原点在主屏左上）；用主屏高度做全局 y 翻转得到 AppKit 全局点，
        // 再按各屏的全局 frame（含 x/y 偏移）判断归属——主副屏一致，无须近似。
        let appKitPoint = CGPoint(x: p.x, y: Self.primaryScreenHeight - p.y)
        return NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
    }

    /// 把生成失败的 error 映射成简洁中文 UI 文案（完整 error 已 NSLog，此处仅面向用户）。
    /// 仅文案优化，不改控制流：网络/鉴权/解析分类，其余给通用兜底。
    private static func userFacingMessage(for error: Error) -> String {
        if let pe = error as? ProviderError {
            switch pe {
            case .missingAPIKey:
                return "失败：未配置 API Key"
            case .network:
                return "失败：网络连接异常"
            case .streamFailed:
                return "失败：响应流异常（请稍后重试）"
            case .invalidResponse:
                return "失败：响应解析异常"
            case .httpError(let status, _):
                switch status {
                case 401, 403:
                    return "失败：鉴权失败（请检查 API Key）"
                case 429:
                    return "失败：请求过于频繁，请稍后重试"
                case 500...599:
                    return "失败：服务端异常（\(status)）"
                default:
                    return "失败：请求出错（\(status)）"
                }
            }
        }
        let ns = error as NSError
        // Foundation URL 层网络错误（如断网/超时）：归为网络异常。
        if ns.domain == NSURLErrorDomain {
            return "失败：网络连接异常"
        }
        return "失败：生成出错，请重试"
    }
}
