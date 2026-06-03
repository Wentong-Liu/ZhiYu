import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限的检查 / 申请 / 跳转设置。
enum AccessibilityAuthorizer {
    /// 当前是否已被信任。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示（首次会引导用户去"系统设置"勾选）。
    static func promptIfNeeded() {
        // 用字面量 key 避免不同 SDK 下 kAXTrustedCheckOptionPrompt 的 CFString/Unmanaged 类型歧义
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 直接打开"系统设置 → 隐私与安全性 → 辅助功能"。
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
