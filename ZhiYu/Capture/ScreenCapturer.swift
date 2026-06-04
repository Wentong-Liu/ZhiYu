import AppKit
import ScreenCaptureKit

@MainActor
enum ScreenCapturer {
    /// 截取全局(左上原点)坐标 rect 区域，返回 PNG 的 data URL；失败返回 nil。
    static func capture(globalRect: CGRect) async -> String? {
        guard globalRect.width > 1, globalRect.height > 1 else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let display = content.displays.first(where: { $0.frame.intersects(globalRect) })
                ?? content.displays.first
            guard let display else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            // sourceRect：相对所在 display 的左上原点、点为单位。
            let local = CGRect(x: globalRect.minX - display.frame.minX,
                               y: globalRect.minY - display.frame.minY,
                               width: globalRect.width, height: globalRect.height)
            cfg.sourceRect = local
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            cfg.width = max(1, Int(local.width * scale))
            cfg.height = max(1, Int(local.height * scale))
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        } catch {
            return nil
        }
    }
}
