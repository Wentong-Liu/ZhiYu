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
                "提示: 首次点击运行可能只是唤醒可访问性，请再点一次「运行 AX 探针」",
                "—— 唤醒可访问性结果 (0 = 成功) ——",
            ]
            lines += r.wakeLines
            lines.append("")
            lines.append("联系人: \(r.contactName)")
            lines.append("AXStaticText 命中数: \(r.rawLines.count)")
            lines.append("输入框焦点: \(r.inputFocused)")
            lines.append("草稿: 「\(r.draft)」")
            lines.append("—— 候选输入框 ——")
            lines += r.candidateLines
            lines.append("选中 composer: \(r.composerLine)")
            lines.append("composer frame: \(r.inputFrame.map { "\($0)" } ?? "nil")")
            lines.append("—— 解析后的消息 (\(r.messages.count)) ——")
            lines += r.messages.map { "\($0.isMe ? "我  " : "对方") | \($0.text)" }
            lines.append("—— 原始可见文本 + x 坐标 ——")
            lines += r.rawLines
            lines.append("—— 完整结构树 dump (\(r.treeLines.count) 节点) ——")
            lines += r.treeLines
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

    /// 验证真实发送路径：粘贴已被证实可用，粘贴生效延时后再模拟回车发送。
    func pasteAndSend() {
        InserterProbe.pasteText("【知语测试】这条是粘贴并发送测试")
        // 粘贴本身有 ~0.25s 延时（写剪贴板 + ⌘V），这里再留足时间等粘贴生效后回车。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            InserterProbe.sendReturn()
        }
        output = "已触发粘贴并将在粘贴生效后回车发送，请仅在「文件传输助手」测试，确认是否发出"
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
                Button("粘贴并发送") { vm.pasteAndSend() }
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
