import SwiftUI
import Combine

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var output: String = "把微信切到某个会话，再点「运行 AX 探针」"

    private let hotkey = GlobalHotkey()

    func runAXProbe() {
        switch WeChatAXProbe.run() {
        case .success(let r):
            var lines = [
                "联系人: \(r.contactName)",
                "输入框焦点: \(r.inputFocused)",
                "输入框 frame: \(r.inputFrame.map { "\($0)" } ?? "nil")",
                "草稿: 「\(r.draft)」",
                "—— 解析后的消息 (\(r.messages.count)) ——",
            ]
            lines += r.messages.map { "\($0.isMe ? "我  " : "对方") | \($0.text)" }
            lines.append("—— 原始可见文本 + x 坐标 ——")
            lines += r.rawLines
            output = lines.joined(separator: "\n")
        case .failure(let e):
            output = "失败: \(e)"
        }
    }

    func insertViaAX() {
        let ok = InserterProbe.setText("【知语测试】这条是 AX 写入测试")
        output = "AX 写入结果: \(ok)（去微信输入框看是否出现文本）"
    }

    func pasteViaClipboard() {
        InserterProbe.pasteText("【知语测试】这条是粘贴兜底测试")
        output = "已触发粘贴（去微信输入框看是否出现文本）"
    }

    func insertAndSend() {
        let ok = InserterProbe.setText("【知语测试】这条是写入并发送测试")
        InserterProbe.sendReturn()
        output = "写入(\(ok))并已模拟回车，请在「文件传输助手」确认是否发出"
    }

    func enableHotkey() {
        hotkey.onTrigger = { [weak self] in self?.runAXProbe() }
        hotkey.start()
        output = "已启用全局快捷键 ⌥⌘R：切到微信任意会话后按它，应自动跑一次 AX 探针并刷新这里"
    }
}

struct ProbeView: View {
    @StateObject private var vm = ProbeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("运行 AX 探针") { vm.runAXProbe() }
                Button("AX 写入输入框") { vm.insertViaAX() }
                Button("粘贴兜底") { vm.pasteViaClipboard() }
                Button("写入并发送") { vm.insertAndSend() }
                Button("启用快捷键 ⌥⌘R") { vm.enableHotkey() }
            }
            ScrollView {
                Text(vm.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
    }
}
