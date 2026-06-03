import AppKit
import ApplicationServices

@MainActor
enum InserterProbe {
    /// 用 AX 直接把文本设进微信输入框。返回是否成功。
    static func setText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = WeChatAXProbe.copyElement(appElement, "AXFocusedWindow")
                ?? WeChatAXProbe.copyElement(appElement, "AXMainWindow") else { return false }
        var texts: [(text: String, frame: CGRect)] = []
        var input: AXUIElement?
        WeChatAXProbe.collect(window, texts: &texts, input: &input)
        guard let field = input else { return false }
        return AXUIElementSetAttributeValue(field, "AXValue" as CFString, text as CFString) == .success
    }

    /// 兜底：写剪贴板 + 模拟 ⌘V 粘贴到当前焦点（用后恢复原剪贴板）。
    static func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        // 完整保存原剪贴板内容（遍历所有 item 的所有 type 存为 Data），
        // 避免只处理 .string 时把用户原本的图片/RTF/文件 URL 等内容破坏掉。
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        WeChatAXProbe.findWeChatApp()?.activate()
        // 记录粘贴前的 changeCount，恢复前确认粘贴已被消费，降低 ⌘V 粘到旧内容 / 过早恢复的竞态。
        let changeCountBeforePaste = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            postKey(9, flags: .maskCommand)            // 'v'
            restoreSnapshotWhenSafe(saved, into: pb, pasteWriteChangeCount: changeCountBeforePaste)
        }
    }

    /// 在确认粘贴已被目标消费后再恢复原剪贴板，最多重试若干次后兜底恢复。
    private static func restoreSnapshotWhenSafe(_ saved: [[String: Data]],
                                                into pb: NSPasteboard,
                                                pasteWriteChangeCount: Int,
                                                attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // changeCount 变化或重试上限到达后再恢复：尽量保证 ⌘V 已读取我们写入的内容。
            if pb.changeCount != pasteWriteChangeCount || attempt >= 4 {
                restore(saved, into: pb)
            } else {
                restoreSnapshotWhenSafe(saved, into: pb,
                                        pasteWriteChangeCount: pasteWriteChangeCount,
                                        attempt: attempt + 1)
            }
        }
    }

    /// 把剪贴板内每个 item 的全部 type 存成 Data，便于无损恢复。
    private static func snapshot(_ pb: NSPasteboard) -> [[String: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        }
    }

    /// 还原 snapshot；若原本为空则不清空用户当前剪贴板，避免数据破坏型副作用。
    private static func restore(_ saved: [[String: Data]], into pb: NSPasteboard) {
        let nonEmpty = saved.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }   // 原本无内容：不动用户剪贴板
        pb.clearContents()
        let items: [NSPasteboardItem] = nonEmpty.map { dict in
            let item = NSPasteboardItem()
            for (typeRaw, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// 模拟回车发送。
    static func sendReturn() {
        postKey(36, flags: [])                          // Return
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
