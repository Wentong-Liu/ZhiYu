import SwiftUI
import Combine

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var output: String = "把微信切到某个会话，再点「运行 AX 探针」"

    private let hotkey = GlobalHotkey()

    func runAXProbe() {
        switch WeChatAXProbe.run() {
        case .success(let r):
            var lines = ["耗时: \(r.elapsedMs) ms"]
            if !r.diagnostics.isEmpty {
                lines.append("—— 诊断 ——")
                lines += r.diagnostics
            }
            lines.append("")
            lines.append("联系人: \(r.contactName)")
            lines.append("输入框焦点: \(r.inputFocused)")
            lines.append("草稿: 「\(r.draft)」")
            lines.append("composer frame: \(r.inputFrame.map { "\($0)" } ?? "nil")")
            lines.append("—— 解析后的消息 (最后 \(r.messages.count) 行) ——")
            lines += r.messages.map { m in
                switch m.speaker {
                case .me: return "我   | \(m.text)"
                case .other:
                    let who = m.name.isEmpty ? "对方" : m.name
                    return "\(who) | \(m.text)"
                case .separator: return "——— \(m.text) ———"
                }
            }
            output = lines.joined(separator: "\n")
        case .failure(let e):
            output = "失败: \(e)"
        }
    }

    /// 整树遍历诊断：会遍历左侧巨表，慢，仅手动触发用于排查结构变化。
    func dumpFullTree() {
        let t0 = ProcessInfo.processInfo.systemUptime
        switch WeChatAXProbe.dumpFullTree() {
        case .success(let treeLines):
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            var lines = ["耗时: \(elapsed) ms（诊断·慢，含左侧巨表）"]
            lines.append("—— 完整结构树 dump (\(treeLines.count) 节点) ——")
            lines += treeLines
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
        let text = "【知语测试】这条是写入并发送测试"
        // a. AX 写入文本。
        let ok = InserterProbe.setText(text)
        // b. 激活微信 + 聚焦 composer：之前只写值没激活/聚焦，回车进了探针窗口导致不发送。
        let located = InserterProbe.focusComposerAndActivate()
        // c. activate() 是异步 fire-and-forget，前台切换/键盘焦点转移由 WindowServer 异步完成，
        //    0.2s 在冷启动/系统忙时可能不足。延时提升到 0.4s（与 pasteAndSend 的 0.45s 量级对齐），
        //    回车前除校验 AXValue 已写入（防发空），再显式校验微信已在前台/输入框已聚焦
        //    （防回车进错窗口导致整条不发送）——二者互补。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let written = InserterProbe.composerValue() ?? ""
            guard written.contains(text) else {
                self.output = "写入(\(ok))/定位(\(located))后校验失败：composer 当前值为「\(written)」，未模拟回车以免发空消息"
                return
            }
            guard InserterProbe.isWeChatFrontFocused() else {
                self.output = "写入(\(ok))/定位(\(located))且草稿已写入，但微信未在前台/输入框未聚焦，未模拟回车以免回车进错窗口（请手动点一下微信再试）"
                return
            }
            InserterProbe.sendReturn()
            self.output = "写入(\(ok))并激活聚焦、前台/焦点校验通过后已模拟回车，请在「文件传输助手」确认是否发出"
        }
        output = "已写入(\(ok))/定位(\(located))，将在激活聚焦后校验 AXValue 与前台/焦点再回车，请在「文件传输助手」确认是否发出"
    }

    /// 验证真实发送路径：粘贴已被证实可用，由粘贴完成回调驱动回车（不再用解耦的独立计时器）。
    func pasteAndSend() {
        // sendReturn 由 pasteText 的 completion 回调驱动：回调在 ⌘V post 之后触发，
        // 这里相对该时刻再留一段时间等微信处理粘贴并把文本提交到输入框，然后回车。
        InserterProbe.pasteText("【知语测试】这条是粘贴并发送测试") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                InserterProbe.sendReturn()
            }
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
            HStack {
                Button("完整结构树（诊断·慢）") { vm.dumpFullTree() }
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
