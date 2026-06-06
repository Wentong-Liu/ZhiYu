import SwiftUI

@main
struct ZhiYuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("知语", systemImage: "bubble.left.and.bubble.right.fill") {
            MenuBarContent()
        }
        Window("知语设置", id: "settings") {
            SettingsView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
