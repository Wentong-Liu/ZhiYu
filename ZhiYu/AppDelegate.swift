import AppKit

/// 把 App 设为菜单栏代理（无 Dock 图标、不抢主窗口焦点），并装上全局右⌘双击监听。
/// 用运行时 activationPolicy(.accessory) 实现，避免改 pbxproj/Info.plist。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let doubleTap = RightCommandDoubleTap()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        doubleTap.onTrigger = {
            CandidatePanelController.shared.trigger()
        }
        doubleTap.start()
    }
}
