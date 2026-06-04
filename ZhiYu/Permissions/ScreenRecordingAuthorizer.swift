import AppKit
import CoreGraphics

/// 屏幕录制（Screen Recording）权限的检查 / 申请 / 跳转设置。识图截屏需要此权限。
enum ScreenRecordingAuthorizer {
    /// 当前是否已被信任（无弹窗的预检）。
    static var isTrusted: Bool { CGPreflightScreenCaptureAccess() }

    /// 申请屏幕录制权限（首次会弹系统授权提示）。
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// 直接打开"系统设置 → 隐私与安全性 → 屏幕录制"。
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
