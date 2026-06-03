import SwiftUI
import Combine

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var output: String = "把微信切到某个会话，再点「运行 AX 探针」"

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
}

struct ProbeView: View {
    @StateObject private var vm = ProbeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("运行 AX 探针") { vm.runAXProbe() }
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
