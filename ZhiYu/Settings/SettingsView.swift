import SwiftUI
import Combine
import ZhiYuCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var kind: ProviderKind { didSet { AppConfig.shared.providerKind = kind; syncForKind() } }
    @Published var model: String { didSet { AppConfig.shared.model = model } }
    @Published var styleIndex: Int { didSet { AppConfig.shared.styleIndex = styleIndex } }
    @Published var apiKey: String = ""
    @Published var status = ""
    @Published var loggedIn = KeychainStore.loadChatGPTTokens() != nil
    let styles = ReplyStyle.presets

    init() {
        kind = AppConfig.shared.providerKind
        model = AppConfig.shared.model
        styleIndex = AppConfig.shared.styleIndex
        switch AppConfig.shared.providerKind {
        case .openAI: apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .chatGPT: apiKey = ""
        }
    }

    func syncForKind() {
        switch kind {
        case .openAI: apiKey = KeychainStore.openAIKey(); if model.isEmpty { model = "gpt-4o" }
        case .deepSeek: apiKey = KeychainStore.deepSeekKey(); model = "deepseek-v4-flash"
        case .chatGPT: model = "gpt-5.5"
        }
    }
    func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openAI: KeychainStore.setOpenAIKey(k); status = "已保存 OpenAI Key"
        case .deepSeek: KeychainStore.setDeepSeekKey(k); status = "已保存 DeepSeek Key"
        case .chatGPT: break
        }
    }
    func login() {
        status = "正在打开浏览器登录…"
        CodexLoginService.shared.login { [weak self] r in
            switch r {
            case .success: self?.loggedIn = true; self?.status = "ChatGPT 登录成功"
            case .failure(let e): self?.status = "登录失败：\(e)"
            }
        }
    }
    func logout() { KeychainStore.clearChatGPTTokens(); loggedIn = false; status = "已退出登录" }
}

private let accent = LinearGradient(
    colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.27, green: 0.79, blue: 0.96)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

struct SettingsView: View {
    @StateObject private var vm = SettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title
                providerSection
                credentialSection
                modelStyleSection
                triggerSection
                if !vm.status.isEmpty {
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 540)
        .background(
            ZStack {
                Color.black.opacity(0.25)
                Rectangle().fill(.ultraThinMaterial)
            }.ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)
    }

    private var title: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent).frame(width: 26, height: 26)
            Text("知语设置").font(.title2.weight(.semibold))
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型来源")
            Picker("", selection: $vm.kind) {
                ForEach(ProviderKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.kind == .chatGPT {
                sectionHeader("ChatGPT 账号")
                HStack(spacing: 10) {
                    Label(vm.loggedIn ? "已登录" : "未登录",
                          systemImage: vm.loggedIn ? "checkmark.seal.fill" : "person.crop.circle")
                        .foregroundStyle(vm.loggedIn ? .green : .secondary)
                    Spacer()
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.login() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                    if vm.loggedIn { Button("退出") { vm.logout() }.buttonStyle(.bordered) }
                }
            } else {
                sectionHeader("API Key")
                HStack(spacing: 10) {
                    SecureField("粘贴你的 API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                    Button("保存") { vm.saveKey() }.buttonStyle(.borderedProminent).tint(.purple)
                }
            }
        }
    }

    private var modelStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型与风格")
            HStack(spacing: 10) {
                TextField("模型名", text: $vm.model).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                Picker("", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }.labelsHidden().frame(width: 130)
            }
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("触发方式")
            HStack(spacing: 8) {
                Image(systemName: "command")
                Text("在微信里 双击右 ⌘ 唤起候选面板").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
    }
}
