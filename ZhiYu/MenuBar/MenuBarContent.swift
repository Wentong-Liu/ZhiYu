import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开探针窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "probe")
        }
        Divider()
        Button("退出知语") { NSApplication.shared.terminate(nil) }
    }
}
