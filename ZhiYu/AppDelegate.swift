import AppKit

/// 把 App 设为菜单栏代理（无 Dock 图标、不抢主窗口焦点），并装上全局修饰键双击监听（默认右⌘）。
/// 用运行时 activationPolicy(.accessory) 实现，避免改 pbxproj/Info.plist。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let doubleTap = ModifierDoubleTap()
    private var isDuplicate = false

    /// 单实例限制：已有同 bundle 的知语在运行，则本次启动直接退出（避免双实例＝两套监听/两个面板）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        guard let myID = me.bundleIdentifier else { return }  // 拿不到 bundleID 则不处理
        let alreadyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == myID && $0.processIdentifier != me.processIdentifier
        }
        if alreadyRunning {
            NSLog("[ZhiYu] 已有知语实例在运行，本次启动退出。")
            isDuplicate = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDuplicate { return }  // 重复实例：不装任何监听，等待 terminate 生效
        NSApp.setActivationPolicy(.accessory)
        doubleTap.onTrigger = {
            CandidatePanelController.shared.trigger()
        }
        doubleTap.start()
        NewMessageWatcher.shared.start()
    }
}
