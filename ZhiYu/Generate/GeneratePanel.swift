import SwiftUI
import Combine
import ZhiYuCore

@MainActor
final class GenerateViewModel: ObservableObject {
    @Published var apiKey: String = KeychainStore.openAIKey()
    @Published var model: String = "gpt-4o"
    @Published var styleIndex: Int = 0
    @Published var status: String = ""
    @Published var candidates: [String] = []
    @Published var isLoading = false

    private let cache = CandidateCache()
    let styles = ReplyStyle.presets

    func saveKey() {
        KeychainStore.setOpenAIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        status = "已保存 API Key 到 Keychain"
    }

    func generate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "请先填写并保存 API Key"; return }
        guard let context = WeChatReader.readCurrentContext(), !context.messages.isEmpty else {
            status = "读不到微信对话（先切到某个会话，且已授权辅助功能）"; return
        }
        let provider = OpenAICompatibleProvider(config: .openAI(model: model), apiKey: key)
        let generator = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
        let style = styles[styleIndex]
        isLoading = true
        status = "生成中…（联系人：\(context.contactName)，\(context.messages.count) 条上下文）"
        candidates = []
        Task {
            do {
                let result = try await generator.generate(context: context, style: style)
                self.candidates = result
                self.status = "完成，\(result.count) 条候选"
            } catch {
                self.status = "失败：\(error)"
            }
            self.isLoading = false
        }
    }

    func fill(_ text: String) {
        Inserter.fill(text)
        status = "已填入：\(text)"
    }

    func send(_ text: String) {
        Inserter.fillAndSend(text) { ok in
            self.status = ok ? "已发送：\(text)" : "未发送（请确认微信在前台且输入框聚焦）"
        }
    }
}

struct GeneratePanel: View {
    @StateObject private var vm = GenerateViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成候选回复").font(.headline)
            HStack {
                SecureField("OpenAI API Key", text: $vm.apiKey)
                Button("保存 Key") { vm.saveKey() }
            }
            HStack {
                TextField("模型", text: $vm.model).frame(width: 160)
                Picker("风格", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in
                        Text(s.name).tag(i)
                    }
                }.frame(width: 160)
                Button(vm.isLoading ? "生成中…" : "生成候选") { vm.generate() }
                    .disabled(vm.isLoading)
            }
            if !vm.status.isEmpty { Text(vm.status).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(vm.candidates.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top) {
                    Text(c).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("填入") { vm.fill(c) }
                    Button("发送") { vm.send(c) }
                }
                .padding(6)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(6)
            }
        }
    }
}
