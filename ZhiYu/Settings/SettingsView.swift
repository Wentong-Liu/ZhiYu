import SwiftUI
import Combine
import ZhiYuCore

/// 设置里把 OpenAI(API Key) 与 ChatGPT 登录归为同一"家族"(OpenAI)，DeepSeek / Anthropic / 智谱GLM / Kimi / MiniMax 各自单独一家族。
enum ProviderFamily: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case glm = "智谱GLM"
    case kimi = "Kimi"
    case minimax = "MiniMax"
    var id: String { rawValue }
}

@MainActor
final class SettingsModel: ObservableObject {
    /// 当前启用的家族（OpenAI / DeepSeek）。
    @Published var family: ProviderFamily { didSet { applyKind() } }
    /// OpenAI 家族下用 ChatGPT 登录(true) 还是 API Key(false)。
    @Published var openAIUsesChatGPT: Bool { didSet { if family == .openAI { applyKind() } } }
    @Published var model: String { didSet { AppConfig.shared.model = model } }
    @Published var styleIndex: Int { didSet { AppConfig.shared.styleIndex = styleIndex } }
    @Published var customPrompt: String { didSet { AppConfig.shared.customPrompt = customPrompt } }
    @Published var autoOnNewMessage: Bool { didSet { AppConfig.shared.autoOnNewMessage = autoOnNewMessage } }
    @Published var apiKey: String = ""
    @Published var status = ""
    @Published var loggedIn = KeychainStore.loadChatGPTTokens() != nil
    /// 辅助功能 / 屏幕录制是否已授权（用于「通用」tab 权限区实时显示）。
    @Published var axGranted: Bool = AccessibilityAuthorizer.isTrusted
    @Published var screenGranted: Bool = ScreenRecordingAuthorizer.isTrusted
    let styles = ReplyStyle.presets

    /// 重新读取系统权限状态（去系统设置授完权切回 App 时调用，自动刷新绿点/按钮）。
    func refreshPermissions() {
        axGranted = AccessibilityAuthorizer.isTrusted
        screenGranted = ScreenRecordingAuthorizer.isTrusted
    }

    /// 家族 + OpenAI 子选择 -> 实际 ProviderKind。
    var currentKind: ProviderKind {
        switch family {
        case .deepSeek: return .deepSeek
        case .anthropic: return .anthropic
        case .glm: return .glm
        case .kimi: return .kimi
        case .minimax: return .minimax
        case .openAI: return openAIUsesChatGPT ? .chatGPT : .openAI
        }
    }

    init() {
        let k = AppConfig.shared.providerKind
        switch k {
        case .deepSeek: family = .deepSeek
        case .anthropic: family = .anthropic
        case .glm: family = .glm
        case .kimi: family = .kimi
        case .minimax: family = .minimax
        default: family = .openAI
        }
        openAIUsesChatGPT = (k == .chatGPT)
        let valid = k.modelOptions.map(\.id)
        model = valid.contains(AppConfig.shared.model) ? AppConfig.shared.model : k.defaultModel
        styleIndex = AppConfig.shared.styleIndex
        autoOnNewMessage = AppConfig.shared.autoOnNewMessage
        customPrompt = ""
        switch k {
        case .openAI: apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .anthropic: apiKey = KeychainStore.anthropicKey()
        case .glm: apiKey = KeychainStore.glmKey()
        case .kimi: apiKey = KeychainStore.kimiKey()
        case .minimax: apiKey = KeychainStore.minimaxKey()
        case .chatGPT: apiKey = ""
        }
        customPrompt = AppConfig.shared.customPrompt
    }

    /// 选择/切换后把 effective kind 写进 AppConfig，并复位 model/凭证显示。
    private func applyKind() {
        let k = currentKind
        AppConfig.shared.providerKind = k
        model = k.defaultModel
        switch k {
        case .openAI: apiKey = KeychainStore.openAIKey()
        case .deepSeek: apiKey = KeychainStore.deepSeekKey()
        case .anthropic: apiKey = KeychainStore.anthropicKey()
        case .glm: apiKey = KeychainStore.glmKey()
        case .kimi: apiKey = KeychainStore.kimiKey()
        case .minimax: apiKey = KeychainStore.minimaxKey()
        case .chatGPT: apiKey = ""
        }
        loggedIn = KeychainStore.loadChatGPTTokens() != nil
    }

    func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentKind {
        case .openAI:
            status = KeychainStore.setOpenAIKey(k) ? "已保存 OpenAI Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
        case .deepSeek:
            status = KeychainStore.setDeepSeekKey(k) ? "已保存 DeepSeek Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
        case .anthropic:
            status = KeychainStore.setAnthropicKey(k) ? "已保存 Anthropic Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
        case .glm:
            status = KeychainStore.setGLMKey(k) ? "已保存 智谱GLM Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
        case .kimi:
            status = KeychainStore.setKimiKey(k) ? "已保存 Kimi Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
        case .minimax:
            status = KeychainStore.setMinimaxKey(k) ? "已保存 MiniMax Key" : "保存失败：无法写入钥匙串，请检查权限后重试"
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

/// 设置窗口的两个选项卡。
private enum SettingsTab: String, CaseIterable, Identifiable {
    case provider = "模型 / Provider"
    case general = "通用设置"
    var id: String { rawValue }
    /// 侧边栏/右侧大标题用的短名称。
    var shortTitle: String {
        switch self {
        case .provider: return "模型"
        case .general:  return "通用"
        }
    }
    /// 侧边栏图标。
    var icon: String {
        switch self {
        case .provider: return "square.stack.3d.up.fill"
        case .general:  return "gearshape"
        }
    }
}

/// 直接配置底层 NSWindow 实现深色透明标题栏（内容延伸到顶、红绿灯浮于深色之上）。
/// 用 NSViewRepresentable 而非 .windowStyle(.hiddenTitleBar)——后者会把菜单栏代理(.accessory)的 App 提升到 Dock，造成回归。
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SettingsView: View {
    @StateObject private var vm = SettingsModel()
    @State private var selectedTab: SettingsTab = .provider

    /// 隐藏系统标题栏后内容延伸到顶；红绿灯浮在左上角，这里为整窗顶部预留的标题栏高度。
    private let titleBarInset: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 16) {
                Text(selectedTab.shortTitle)
                    .font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.95))
                switch selectedTab {
                case .provider: providerTab
                case .general:  generalTab
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .padding(.top, titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 720, height: 600)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11).ignoresSafeArea())
        .background(WindowConfigurator())
        .environment(\.colorScheme, .dark)
        .onAppear { vm.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshPermissions()
        }
    }

    /// 左侧导航栏：品牌头（图标 + 知语设置）+ 各选项卡导航项。
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 品牌头放到标题栏那一行，向右挪开红绿灯（leading 内边距让它出现在红绿灯右侧、同一行）。
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)))
                Text("知语设置").font(.headline).foregroundStyle(.white.opacity(0.95))
            }
            .padding(.leading, 10)
            .padding(.bottom, 4)

            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, titleBarInset)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = (tab == selectedTab)
        return HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 14))
                .frame(width: 18)
                .foregroundStyle(selected ? .white.opacity(0.95) : .white.opacity(0.55))
            Text(tab.shortTitle)
                .font(.callout)
                .foregroundStyle(selected ? .white.opacity(0.95) : .white.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = tab }
        .animation(.easeOut(duration: 0.14), value: selected)
    }

    /// 「模型 / Provider」选项卡：provider 卡 + 模型/风格 + 存 Key 的 status 文案。
    private var providerTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                providerSection
                modelStyleSection
                if !vm.status.isEmpty {
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「通用设置」选项卡：触发方式（双击右 ⌘）+ 新消息自动生成候选。
    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionSection
                triggerSection
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「权限」区：辅助功能 + 屏幕录制两张卡；已授权显示绿点，否则「去授权」按钮。
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("权限")
            permissionCard(name: "辅助功能",
                           desc: "读消息、填入/发送、转文字、发表情都需要",
                           granted: vm.axGranted) {
                AccessibilityAuthorizer.promptIfNeeded()
                AccessibilityAuthorizer.openSettings()
            }
            permissionCard(name: "屏幕录制",
                           desc: "识别图片/表情需要；不授权时图片按纯文本处理",
                           granted: vm.screenGranted) {
                _ = ScreenRecordingAuthorizer.request()
                ScreenRecordingAuthorizer.openSettings()
            }
        }
    }

    /// 单张权限卡：左侧名称+小字说明，右侧已授权绿点或「去授权」按钮。
    private func permissionCard(name: String, desc: String, granted: Bool,
                                onAuthorize: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).foregroundStyle(.white.opacity(0.9))
                Text(desc).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("已授权").font(.callout).foregroundStyle(.white.opacity(0.9))
                }
            } else {
                Button("去授权", action: onAuthorize).buttonStyle(MonoButton(filled: true))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    // MARK: 模型来源 —— 纵向列表 + 单选

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型来源")
            VStack(spacing: 8) {
                openAIRow
                deepSeekRow
                anthropicRow
                glmRow
                kimiRow
                minimaxRow
            }
        }
    }

    private var openAIRow: some View {
        providerCard(selected: vm.family == .openAI, title: "OpenAI",
                     subtitle: "API Key 或 ChatGPT 订阅登录",
                     onSelect: { vm.family = .openAI }) {
            monoSegment(options: [("key", "API Key"), ("chatgpt", "ChatGPT 登录")],
                        selectedID: vm.openAIUsesChatGPT ? "chatgpt" : "key") { id in
                vm.openAIUsesChatGPT = (id == "chatgpt")
            }
            if vm.openAIUsesChatGPT {
                HStack(spacing: 10) {
                    Label(vm.loggedIn ? "已登录" : "未登录",
                          systemImage: vm.loggedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.callout).foregroundStyle(vm.loggedIn ? .white.opacity(0.9) : .secondary)
                    Spacer()
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.login() }
                        .buttonStyle(MonoButton(filled: true))
                    if vm.loggedIn { Button("退出") { vm.logout() }.buttonStyle(MonoButton()) }
                }
            } else {
                HStack(spacing: 10) {
                    SecureField("OpenAI API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                    Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
                }
            }
        }
    }

    private var deepSeekRow: some View {
        providerCard(selected: vm.family == .deepSeek, title: "DeepSeek",
                     subtitle: "API Key",
                     onSelect: { vm.family = .deepSeek }) {
            HStack(spacing: 10) {
                SecureField("DeepSeek API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    private var anthropicRow: some View {
        providerCard(selected: vm.family == .anthropic, title: "Anthropic",
                     subtitle: "Claude · API Key",
                     onSelect: { vm.family = .anthropic }) {
            HStack(spacing: 10) {
                SecureField("Anthropic API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    private var glmRow: some View {
        providerCard(selected: vm.family == .glm, title: "智谱GLM",
                     subtitle: "API Key",
                     onSelect: { vm.family = .glm }) {
            HStack(spacing: 10) {
                SecureField("智谱GLM API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    private var kimiRow: some View {
        providerCard(selected: vm.family == .kimi, title: "Kimi",
                     subtitle: "API Key",
                     onSelect: { vm.family = .kimi }) {
            HStack(spacing: 10) {
                SecureField("Kimi API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    private var minimaxRow: some View {
        providerCard(selected: vm.family == .minimax, title: "MiniMax",
                     subtitle: "API Key",
                     onSelect: { vm.family = .minimax }) {
            HStack(spacing: 10) {
                SecureField("MiniMax API Key", text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    @ViewBuilder
    private func providerCard<Content: View>(selected: Bool, title: String, subtitle: String,
                                             onSelect: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? .white.opacity(0.95) : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.95))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Text("当前启用").font(.caption2).foregroundStyle(.white.opacity(0.55)) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            if selected { content() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(selected ? 0.07 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.white.opacity(selected ? 0.18 : 0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.16), value: selected)
    }

    private func monoSegment(options: [(id: String, label: String)], selectedID: String,
                             onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.id) { o in
                Button { onSelect(o.id) } label: {
                    Text(o.label).font(.caption)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(selectedID == o.id ? .white : .secondary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(selectedID == o.id ? 0.16 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
    }

    // MARK: 模型与风格

    private var modelStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型与风格")
            HStack(spacing: 10) {
                Picker("", selection: $vm.model) {
                    ForEach(vm.currentKind.modelOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .labelsHidden().tint(.white).frame(maxWidth: .infinity)

                Picker("", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in
                        Text(s.name).tag(i)
                    }
                    Text("自定义").tag(vm.styles.count)
                }
                .labelsHidden().tint(.white).frame(width: 130)
            }
            if !vm.currentKind.supportsMultimodal {
                Text("⚠️ 当前模型不支持多模态，无法识别图片和表情包（图片消息将按纯文本处理）")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if vm.styleIndex >= vm.styles.count {
                TextEditor(text: $vm.customPrompt)
                    .font(.callout)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.1)))
                    .overlay(alignment: .topLeading) {
                        if vm.customPrompt.isEmpty {
                            Text("写给大模型的提示词，例如：用我一贯的简短、略带调侃的口吻回复，多用语气词。")
                                .font(.callout).foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                        }
                    }
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

            VStack(alignment: .leading, spacing: 4) {
                Toggle("新消息自动生成候选（切到微信前台时弹出）", isOn: $vm.autoOnNewMessage)
                    .toggleStyle(.switch).tint(.white)
                    .foregroundStyle(.white.opacity(0.9))
                Text("对方发来新消息时后台预生成；切到微信前台时弹出候选。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        }
    }
}
