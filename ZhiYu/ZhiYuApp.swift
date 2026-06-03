import SwiftUI

@main
struct ZhiYuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("知语", systemImage: "bubble.left.and.bubble.right") {
            MenuBarContent()
        }
        Window("知语 · 探针", id: "probe") {
            ProbeView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // 启动不自动弹窗，仅菜单点击时打开
    }
}
