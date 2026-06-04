import AppKit
import ZhiYuCore

/// 【临时诊断热键】**双击左 Command**（keyCode 55）→ dump 当前打开的微信表情面板 AX 结构。
/// 复用与「双击右⌘唤起候选」相同的 flagsChanged 全局监听机制（已验证可用、不抢焦点、不需 Input Monitoring）。
/// 全局监听只观察不消费事件，所以微信表情面板的 popover 不会被关掉。
/// 仅诊断用，验证完连同 StickerPanelProbe 一起删除。
@MainActor
final class StickerProbeHotkey {
    private var flagsMonitor: Any?
    private var detector = DoubleTapDetector(threshold: 0.4)
    private static let leftCommandKeyCode: UInt16 = 55

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            // 只认左 Command 的「按下」边沿；夹其它键则重置，避免组合键误触。
            guard event.keyCode == Self.leftCommandKeyCode,
                  event.modifierFlags.contains(.command) else {
                if event.keyCode != Self.leftCommandKeyCode { self.detector.reset() }
                return
            }
            if self.detector.registerPress(at: event.timestamp) {
                StickerPanelProbe.dump()
            }
        }
    }

    func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }
}
