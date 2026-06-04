import SwiftUI
import Combine
import ZhiYuCore

@MainActor
final class GenerateViewModel: ObservableObject {
    // kind/model/styleIndex 以 AppConfig（UserDefaults）为唯一事实来源；
    // @Published 仅作 UI 镜像，didSet 回写 AppConfig，使悬浮面板/双击触发也能读到当前配置。
    @Published var kind: ProviderKind = AppConfig.shared.providerKind {
        didSet { AppConfig.shared.providerKind = kind }
    }
    @Published var apiKey: String = KeychainStore.openAIKey()
    @Published var model: String = AppConfig.shared.model {
        didSet { AppConfig.shared.model = model }
    }
    @Published var styleIndex: Int = AppConfig.shared.styleIndex {
        didSet { AppConfig.shared.styleIndex = styleIndex }
    }
    @Published var status: String = ""
    @Published var candidates: [String] = []
    @Published var isLoading = false
    @Published var loggedIn: Bool = KeychainStore.loadChatGPTTokens() != nil

    private let cache = CandidateCache()
    let styles = ReplyStyle.presets

    init() {
        // 按当前 Provider 同步默认 key（model 由 AppConfig 提供，不覆盖用户已选模型）。
        switch kind {
        case .openAI:  apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .chatGPT: break
        }
    }

    /// 切换 Provider 时调整默认 key/model。
    func onKindChange() {
        switch kind {
        case .openAI:  apiKey = KeychainStore.openAIKey();  if model.isEmpty { model = "gpt-4o" }
        case .deepSeek: apiKey = KeychainStore.deepSeekKey(); model = "deepseek-v4-flash"
        case .chatGPT: model = "gpt-5.5"
        }
    }

    func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openAI:  KeychainStore.setOpenAIKey(k);  status = "已保存 OpenAI Key"
        case .deepSeek: KeychainStore.setDeepSeekKey(k); status = "已保存 DeepSeek Key"
        case .chatGPT: break
        }
    }

    func loginChatGPT() {
        status = "正在打开浏览器登录 ChatGPT…"
        CodexLoginService.shared.login { result in
            switch result {
            case .success: self.loggedIn = true; self.status = "ChatGPT 登录成功"
            case .failure(let e): self.status = "登录失败：\(e)"
            }
        }
    }

    func logoutChatGPT() {
        KeychainStore.clearChatGPTTokens(); loggedIn = false; status = "已退出 ChatGPT 登录"
    }

    func generate() {
        guard let context = WeChatReader.readCurrentContext(), !context.messages.isEmpty else {
            status = "读不到微信对话（先切到某个会话，且已授权辅助功能）"; return
        }
        let style = styles[styleIndex]
        isLoading = true; candidates = []
        status = "生成中…（联系人：\(context.contactName)，\(context.messages.count) 条上下文）"
        // 生成前把当前选择同步进 AppConfig，悬浮面板/双击触发与探针面板用同一套配置。
        AppConfig.shared.providerKind = kind
        AppConfig.shared.model = model
        AppConfig.shared.styleIndex = styleIndex
        Task {
            do {
                let provider = try await ProviderFactory.make()
                let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
                let result = try await gen.generate(context: context, style: style)
                self.candidates = result
                self.status = "完成，\(result.count) 条候选"
            } catch {
                self.status = "失败：\(error)"
            }
            self.isLoading = false
        }
    }

    func fill(_ text: String) { Inserter.fill(text); status = "已填入" }
    func send(_ text: String) {
        Inserter.fillAndSend(text) { ok in
            self.status = ok ? "已发送" : "未发送（确认微信在前台且输入框聚焦）"
        }
    }
}

struct GeneratePanel: View {
    @StateObject private var vm = GenerateViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成候选回复").font(.headline)
            Picker("Provider", selection: $vm.kind) {
                ForEach(ProviderKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.kind) { _, _ in vm.onKindChange() }

            if vm.kind == .chatGPT {
                HStack {
                    Text(vm.loggedIn ? "已登录 ChatGPT ✓" : "未登录")
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.loginChatGPT() }
                    if vm.loggedIn { Button("退出登录") { vm.logoutChatGPT() } }
                }
            } else {
                HStack {
                    SecureField("API Key", text: $vm.apiKey)
                    Button("保存 Key") { vm.saveKey() }
                }
            }

            HStack {
                TextField("模型", text: $vm.model).frame(width: 160)
                Picker("风格", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }.frame(width: 160)
                Button(vm.isLoading ? "生成中…" : "生成候选") { vm.generate() }.disabled(vm.isLoading)
            }
            if !vm.status.isEmpty { Text(vm.status).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(vm.candidates.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top) {
                    Text(c).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("填入") { vm.fill(c) }
                    Button("发送") { vm.send(c) }
                }
                .padding(6).background(Color.gray.opacity(0.12)).cornerRadius(6)
            }
        }
    }
}
