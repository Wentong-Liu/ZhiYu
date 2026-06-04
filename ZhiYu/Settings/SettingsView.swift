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
        case .openAI: apiKey = KeychainStore.openAIKey(); model = "gpt-4o"
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

/// 黑白灰按钮：filled=true 为主操作（稍亮的灰底），否则次级（更淡）。
private struct MonoButton: ButtonStyle {
    var filled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(.white.opacity(0.92))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(filled
                        ? (configuration.isPressed ? 0.26 : 0.18)
                        : (configuration.isPressed ? 0.12 : 0.06)))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.1)))
    }
}

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
        .background(Color(red: 0.10, green: 0.10, blue: 0.11).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var title: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)))
            Text("知语设置").font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.95))
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型来源")
            HStack(spacing: 4) {
                ForEach(ProviderKind.allCases) { k in
                    Button { vm.kind = k } label: {
                        Text(k.rawValue)
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(vm.kind == k ? .white : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.white.opacity(vm.kind == k ? 0.16 : 0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
        }
    }

    @ViewBuilder private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.kind == .chatGPT {
                sectionHeader("ChatGPT 账号")
                HStack(spacing: 10) {
                    Label(vm.loggedIn ? "已登录" : "未登录",
                          systemImage: vm.loggedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(vm.loggedIn ? .white.opacity(0.9) : .secondary)
                    Spacer()
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.login() }
                        .buttonStyle(MonoButton(filled: true))
                    if vm.loggedIn { Button("退出") { vm.logout() }.buttonStyle(MonoButton()) }
                }
            } else {
                sectionHeader("API Key")
                HStack(spacing: 10) {
                    SecureField("粘贴你的 API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                    Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
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
                }.labelsHidden().frame(width: 130).tint(.white)
            }
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("触发方式")
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.white.opacity(0.8))
                Text("在微信里 双击右 ⌘ 唤起候选面板").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        }
    }
}
