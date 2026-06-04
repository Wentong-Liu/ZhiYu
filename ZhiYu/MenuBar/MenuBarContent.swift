import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AccessibilityAuthorizer.isTrusted ? "辅助功能：已授权 ✓" : "辅助功能：去授权…") {
            if AccessibilityAuthorizer.isTrusted {
                AccessibilityAuthorizer.openSettings()
            } else {
                AccessibilityAuthorizer.promptIfNeeded()
                AccessibilityAuthorizer.openSettings()
            }
        }
        Button("知语设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
