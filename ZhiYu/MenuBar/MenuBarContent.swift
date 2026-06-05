import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if AccessibilityAuthorizer.isTrusted {
                AccessibilityAuthorizer.openSettings()
            } else {
                AccessibilityAuthorizer.promptIfNeeded()
                AccessibilityAuthorizer.openSettings()
            }
        } label: {
            Label {
                Text(AccessibilityAuthorizer.isTrusted ? "辅助功能：已授权" : "辅助功能：去授权…")
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(AccessibilityAuthorizer.isTrusted ? Color.green : Color.secondary)
            }
        }
        Button {
            if !ScreenRecordingAuthorizer.isTrusted { ScreenRecordingAuthorizer.request() }
            ScreenRecordingAuthorizer.openSettings()
        } label: {
            Label {
                Text(ScreenRecordingAuthorizer.isTrusted ? "屏幕录制：已授权" : "屏幕录制：去授权…（识图需要）")
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(ScreenRecordingAuthorizer.isTrusted ? Color.green : Color.secondary)
            }
        }
        Button("设置") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
