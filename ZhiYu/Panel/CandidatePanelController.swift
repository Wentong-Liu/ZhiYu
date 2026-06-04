import AppKit
import SwiftUI
import ZhiYuCore

/// 管理候选悬浮面板：双击触发后 读会话 -> 定位 -> 生成 -> 展示 -> 填入/发送 -> 消失。
@MainActor
final class CandidatePanelController: NSObject {
    static let shared = CandidatePanelController()

    /// 面板布局常量。
    private enum Layout {
        /// 面板底边与 composer 顶边的间隙。
        static let gap: CGFloat = 8
        /// 面板可用高度下限（屏太矮时的兜底）。
        static let minHeight: CGFloat = 220
        /// 面板高度相对屏 visibleFrame 上下留白。
        static let screenMargin: CGFloat = 24
    }

    private var panel: NSPanel?
    private var anchorAXFrame: CGRect = .zero
    private let model = CandidatePanelModel()
    private let cache = CandidateCache()
    private var keyMonitor: Any?
    private var escGlobalMonitor: Any?

    /// 按联系人记的"已展示/已建基线"会话指纹：只有当前打开会话的指纹相对基线变化、且最后一条是对方发的，
    /// 才算新消息。避免"联系人 A 来消息但当前开着 B"时误把 B 当新消息弹出来。
    private var lastSeenSig: [String: String] = [:]
    /// 按联系人记的"已预暖"会话指纹（预暖去重）。
    private var lastPrewarmSig: [String: String] = [:]
    /// 上次廉价指纹（高频去重前移：相同则不跑昂贵的完整快读）。
    private var lastCheapSignature: String?
    /// 一次 present 的 Task 是否在飞：转文字会改动微信 AX→触发 watcher，须在此期间抑制自动评估的 re-entry，避免重复弹。
    private var isBusy = false
    /// present 代际令牌：新 present 取代在飞旧 present 时自增，旧 Task 完成时凭此识别自己已陈旧、不再写回。
    private var presentGeneration = 0
    /// 当前在飞的 present 任务：ESC/dismiss 时取消，让转写循环立即停、不再 AXShowMenu/把微信拉前台。
    private var currentTask: Task<Void, Never>?

    /// 双击触发：读当前会话快照并展示。
    func trigger() {
        // 只跑一次 AX 探针：上下文与输入框 frame 来自同一快照，避免两次遍历观察到不一致的会话状态。
        guard let snapshot = WeChatReader.readSnapshot() else { NSSound.beep(); return }
        present(snapshot: snapshot)
    }

    /// 用给定快照展示候选面板（手动/自动共用）。
    private func present(snapshot: WeChatReader.Snapshot) {
        guard !snapshot.context.messages.isEmpty, let frame = snapshot.composerFrame else { NSSound.beep(); return }
        dismiss()  // 重复展示前先收掉残留面板/监听，避免层叠
        isBusy = true
        presentGeneration += 1
        let generation = presentGeneration
        var baseContext = snapshot.context
        var imageFrames = snapshot.imageFrames
        // 先复位到加载态再建面板：面板按"加载态"测高，内容到位后再 relayout，避免沿用上次内容的尺寸。
        model.isLoading = true
        model.loadingNote = "生成中…"
        model.candidates = []
        model.stickerKeyword = nil
        model.status = ""
        model.providerLabel = AppConfig.shared.providerLabel
        lastSeenSig[snapshot.context.contactName] = MessageSignal.signature(snapshot.context)  // 标记已展示
        showPanel(anchorAXFrame: frame)
        let style = AppConfig.shared.currentStyle()
        currentTask?.cancel()  // 取代在飞的旧任务（其转写循环会响应取消立即停）
        currentTask = Task {
            do {
                // 若会话里有"未转文字"的语音 → 取最近 5 条触发转写并等到完成，转写回来后重读。
                // transcribeRecentAndWait 已等到转写落地，故重读拿到的是转写后的文本，generate 不会用 [语音] 占位。
                if baseContext.messages.contains(where: { $0.text.contains(WeChatMarkers.voicePlaceholder) }) {
                    if generation == self.presentGeneration { self.model.loadingNote = "转写语音中…" }
                    await VoiceTranscriber.transcribeRecentAndWait()
                    if Task.isCancelled { return }  // ESC 已取消：不再重读/生成
                    if let fresh = WeChatReader.readSnapshot() {
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
            } catch {
                guard generation == self.presentGeneration else { return }  // 陈旧任务：新 present 已接管，不写、不动 isBusy
                self.model.isLoading = false
                // UI 文案：对网络/鉴权/解析做简洁中文映射；完整 error 仅 NSLog 便于诊断（控制流不变）。
                NSLog("[ZhiYu] 生成失败 error=%@", String(describing: error))
                self.model.status = Self.userFacingMessage(for: error)
                self.relayout()
                self.isBusy = false
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
            lastCheapSignature = cheap
        }
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

    private func showPanel(anchorAXFrame axFrame: CGRect) {
        self.anchorAXFrame = axFrame
        model.onFill = { [weak self] t in Inserter.fill(t); self?.dismiss() }
        model.onSend = { [weak self] t in Inserter.sendSequential(BubbleSplitter.split(t)); self?.dismiss() }
        model.onSendSticker = { [weak self] kw in self?.dismiss(); StickerSender.send(keyword: kw) }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CandidatePanelView.baseWidth, height: 120),
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
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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

        // AX->AppKit 全局 y 翻转（基于主屏高度）；外边距 pad 从 gap/x 扣除以保持卡片视觉位置。
        var origin = PanelPositioning.panelOrigin(composerAXFrame: axFrame,
                                                  primaryScreenHeight: Self.primaryScreenHeight, gap: Layout.gap - pad)
        origin.x -= pad
        origin.x = max(vf.minX, min(origin.x, vf.maxX - width))
        origin.y = max(vf.minY, min(origin.y, vf.maxY - panelH))
        panel.setFrameOrigin(origin)
    }

    /// 面板存活期间的键盘处理：
    /// - 本地监听：1/2/3 选中、Esc 关闭（面板恰为 key 时生效）。
    /// - 全局 Esc 监听：自动弹出时微信在前台、本地监听收不到键，故再加全局 Esc 兜底关闭
    ///   （只观察不吞事件，Esc 漏给微信无害）。不再监听"外部点击消失"——别的 app 弹窗点击会误关面板。
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
            if chars == "\u{1B}" { // Esc
                self.dismiss(); return nil
            }
            return event
        }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return }
            if (event.charactersIgnoringModifiers ?? "") == "\u{1B}" { self.dismiss() }
        }
    }

    func dismiss() {
        currentTask?.cancel(); currentTask = nil  // 取消在飞转写/生成，转写循环立即停、不再 AXShowMenu/拉前台
        isBusy = false                            // 取消后不要卡在 busy，否则自动评估会被一直抑制
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }
        panel?.close()
        panel = nil
    }

    /// 主显示器（含 AppKit 全局原点、frame.origin == (0,0) 的屏）的高度；AX/CG 全局 y 翻转的基准。
    /// AX 与 AppKit 共享全局平面、原点都锚在主屏，故用主屏高度做 `appKitY = h - axY` 的全局换算。
    private static var primaryScreenHeight: CGFloat {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        return primary?.frame.height ?? 1000
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
