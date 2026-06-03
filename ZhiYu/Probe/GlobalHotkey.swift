import AppKit

/// 探针用全局快捷键监听（⌥⌘R）。基于全局事件监听，不消费事件，仅用于验证可行性；
/// 正式版会换成 RegisterEventHotKey 以独占快捷键。
@MainActor
final class GlobalHotkey {
    private var monitor: Any?
    var onTrigger: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌥⌘R：option + command + R(keyCode 15)
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == [.command, .option], event.keyCode == 15 {
                self?.onTrigger?()
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
