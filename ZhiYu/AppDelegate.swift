import AppKit

/// 把 App 设为菜单栏代理（无 Dock 图标、不抢主窗口焦点）。
/// 用运行时 activationPolicy(.accessory) 实现，避免改 pbxproj/Info.plist。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
