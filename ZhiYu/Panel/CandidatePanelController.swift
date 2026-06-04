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
