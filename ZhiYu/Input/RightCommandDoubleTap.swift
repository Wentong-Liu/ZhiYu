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
