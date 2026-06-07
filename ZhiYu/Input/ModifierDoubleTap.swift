import AppKit
import ZhiYuCore

/// 全局监听「双击某个修饰键」唤起候选面板。具体是哪个键由 AppConfig.shared.triggerKey 决定
/// （默认右⌘，键码见 TriggerKey）。在 flagsChanged 回调里**实时读** triggerKey，用户改设置后立即生效、无需重启监听。
/// 用 flagsChanged 捕捉目标键的「按下」边沿；夹了其它键按下则重置，避免 ⌘C/⌘V 误触。
@MainActor
final class ModifierDoubleTap {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var detector = DoubleTapDetector(threshold: 0.4)
    var onTrigger: (() -> Void)?

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            // 实时读当前设置的触发键，改了立即生效。
            let key = AppConfig.shared.triggerKey
            // 只认目标键的「按下」边沿（其修饰标志此刻为 set）。
            guard event.keyCode == key.keyCode,
                  event.modifierFlags.contains(key.flag) else {
                // 目标键抬起或其它修饰键变化：不计为按下；其它修饰键打断双击。
                if event.keyCode != key.keyCode { self.detector.reset() }
                return
            }
            if self.detector.registerPress(at: event.timestamp) {
                self.onTrigger?()
            }
        }
        // 任意普通按键按下 -> 打断双击（避免 修饰键+键 组合被当成双击的一半）。
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.reset()
        }
    }

    func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
