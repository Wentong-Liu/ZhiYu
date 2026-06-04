import AppKit
import SwiftUI
import ZhiYuCore

/// 管理候选悬浮面板：双击触发后 读会话 -> 定位 -> 生成 -> 展示 -> 填入/发送 -> 消失。
@MainActor
final class CandidatePanelController: NSObject {
    static let shared = CandidatePanelController()

    private var panel: NSPanel?
    private let model = CandidatePanelModel()
    private let cache = CandidateCache()
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    /// 双击触发入口。
    func trigger() {
        // 只跑一次 AX 探针：上下文与输入框 frame 来自同一快照，避免两次遍历观察到不一致的会话状态。
        guard let snapshot = WeChatReader.readSnapshot(), !snapshot.context.messages.isEmpty,
              let frame = snapshot.composerFrame else {
            NSSound.beep(); return
        }
        let context = snapshot.context
        showPanel(anchorAXFrame: frame)
        model.isLoading = true
        model.candidates = []
        model.status = ""
        model.providerLabel = AppConfig.shared.providerLabel
        let style = AppConfig.shared.currentStyle()
        Task {
            do {
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: self.cache, candidateCount: 3, modelTag: AppConfig.shared.modelTag)
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
        model.onSend = { [weak self] t in Inserter.sendSequential(BubbleSplitter.split(t)); self?.dismiss() }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let screen = screenContaining(axPointTopLeft: CGPoint(x: axFrame.midX, y: axFrame.minY))
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let available = max(220, vf.height - 24)

        // 1) 测自然内容高度（不滚动）
        let measure = NSHostingView(rootView: CandidatePanelView(model: model, scrollable: false, maxHeight: .greatestFiniteMagnitude))
        measure.layout()
        let natural = measure.fittingSize
        let width = max(natural.width, 440)
        let needScroll = natural.height > available
        let panelH = min(natural.height, available)

        // 2) 实际 hosting：超高则滚动，固定高度 = panelH
        let hosting = NSHostingView(rootView: CandidatePanelView(model: model, scrollable: needScroll, maxHeight: panelH))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: panelH)
        hosting.layout()
        let size = NSSize(width: width, height: panelH)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.contentView = hosting

        var origin = PanelPositioning.panelOrigin(composerAXFrame: axFrame,
                                                  screenHeight: screen?.frame.height ?? 1000, gap: 8)
        // size.height 已 <= available <= vf.height，夹取必落在屏内
        origin.x = max(vf.minX, min(origin.x, vf.maxX - size.width))
        origin.y = max(vf.minY, min(origin.y, vf.maxY - size.height))
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        self.panel = p

        installKeyMonitor()
        installOutsideClickMonitor()
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

    /// 点击面板之外 -> 消失。nonactivatingPanel + accessory app 下 key 状态不可靠，
    /// 不用 windowDidResignKey；改用显式的鼠标按下监听做确定性的「外部点击」消失。
    /// - 全局监听：捕捉投向微信等其它 app 的点击（global monitor 只观察、不吞事件，点击照常落到微信）。
    /// - 本地监听：捕捉投向本 app 自身的点击；若不在面板矩形内则消失，在面板内则放行（选卡片/发送）。
    private func installOutsideClickMonitor() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismiss()
        }
        // 本地监听需要返回 event；面板内点击放行，面板外点击消失。
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }   // 面板内：放行（onTap/发送按钮）
            self.dismiss()
            return event
        }
        // 把本地监听一并挂在同一字段链上，dismiss 时统一移除。
        localClickMonitor = local
    }

    func dismiss() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
        panel?.close()
        panel = nil
    }

    private func screenContaining(axPointTopLeft p: CGPoint) -> NSScreen? {
        // AX 点为左上原点；转 AppKit 后判断落在哪个屏幕。用主屏高换算近似（多屏精确换算 Phase 5 再细化）。
        let h = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: p.x, y: h - p.y)
        return NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
    }
}
