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
        // 临时诊断：导出当前会话消息行 AX 结构(含 frame) 到文件（排查图片/表情，确认后删）
        Button("诊断：导出会话AX") {
            let text = WeChatAXProbe.dumpMessageRows().joined(separator: "\n")
            let url = URL(fileURLWithPath: "/Users/liuwentong/Project/me/ZhiYu/.local-notes/img-ax.txt")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
