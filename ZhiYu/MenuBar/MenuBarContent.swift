import SwiftUI
import AppKit

private func statusDot(_ color: NSColor) -> NSImage {
    let size = NSSize(width: 9, height: 9)
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

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
            HStack {
                Text("辅助功能")
                Spacer()
                Image(nsImage: statusDot(AccessibilityAuthorizer.isTrusted ? .systemGreen : .systemGray))
                    .renderingMode(.original)
            }
        }
        Button {
            if !ScreenRecordingAuthorizer.isTrusted { ScreenRecordingAuthorizer.request() }
            ScreenRecordingAuthorizer.openSettings()
        } label: {
            HStack {
                Text("屏幕录制")
                Spacer()
                Image(nsImage: statusDot(ScreenRecordingAuthorizer.isTrusted ? .systemGreen : .systemGray))
                    .renderingMode(.original)
            }
        }
        Button("设置") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}
