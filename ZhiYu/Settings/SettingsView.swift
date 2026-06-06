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

    /// 该家族对应的 ProviderKind。openAI 家族取「非 ChatGPT」的 .openAI（ChatGPT 子选择在 SettingsModel.currentKind 处理）。
    var defaultKind: ProviderKind {
        switch self {
        case .openAI:    return .openAI
        case .deepSeek:  return .deepSeek
        case .anthropic: return .anthropic
        case .glm:       return .glm
        case .kimi:      return .kimi
        case .minimax:   return .minimax
        }
    }

    /// 由 ProviderKind 反推家族。.chatGPT 归入 OpenAI 家族（与 openAIUsesChatGPT 配合）。
    init(kind: ProviderKind) {
        switch kind {
        case .deepSeek:  self = .deepSeek
        case .anthropic: self = .anthropic
        case .glm:       self = .glm
        case .kimi:      self = .kimi
        case .minimax:   self = .minimax
        case .openAI, .chatGPT: self = .openAI
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    /// 当前启用的家族（OpenAI / DeepSeek / Anthropic / 智谱GLM / Kimi / MiniMax，见 ProviderFamily）。
    @Published var family: ProviderFamily { didSet { applyKind() } }
    /// OpenAI 家族下用 ChatGPT 登录(true) 还是 API Key(false)。
    @Published var openAIUsesChatGPT: Bool { didSet { if family == .openAI { applyKind() } } }
    @Published var model: String { didSet { AppConfig.shared.model = model } }
    @Published var styleIndex: Int { didSet { AppConfig.shared.styleIndex = styleIndex } }
    @Published var customPrompt: String { didSet { AppConfig.shared.customPrompt = customPrompt } }
    @Published var autoOnNewMessage: Bool { didSet { AppConfig.shared.autoOnNewMessage = autoOnNewMessage } }
    /// 触发候选面板的「双击修饰键」。改了立即写回 AppConfig，监听处实时生效。
    @Published var triggerKey: TriggerKey { didSet { AppConfig.shared.triggerKey = triggerKey } }
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
        if family == .openAI { return openAIUsesChatGPT ? .chatGPT : .openAI }
        return family.defaultKind
    }

    init() {
        let k = AppConfig.shared.providerKind
        family = ProviderFamily(kind: k)
        openAIUsesChatGPT = (k == .chatGPT)
        let valid = k.modelOptions.map(\.id)
        model = valid.contains(AppConfig.shared.model) ? AppConfig.shared.model : k.defaultModel
        styleIndex = AppConfig.shared.styleIndex
        autoOnNewMessage = AppConfig.shared.autoOnNewMessage
        triggerKey = AppConfig.shared.triggerKey
        customPrompt = ""
        apiKey = KeychainStore.apiKey(for: k)
        customPrompt = AppConfig.shared.customPrompt
    }

    /// 选择/切换后把 effective kind 写进 AppConfig，并复位 model/凭证显示。
    private func applyKind() {
        let k = currentKind
        AppConfig.shared.providerKind = k
        model = k.defaultModel
        apiKey = KeychainStore.apiKey(for: k)
        loggedIn = KeychainStore.loadChatGPTTokens() != nil
    }

    func saveKey() {
        let kind = currentKind
        guard kind != .chatGPT else { return }
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        status = KeychainStore.setAPIKey(k, for: kind)
            ? "已保存 \(kind.displayName) Key"
            : "保存失败：无法写入钥匙串，请检查权限后重试"
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

/// OpenAI 家族下的凭证方式分段：API Key 还是 ChatGPT 登录。
/// 取代原先 monoSegment 里的裸字符串 id（"key" / "chatgpt"），与 `openAIUsesChatGPT` 一一对应。
private enum OpenAIAuthMode: CaseIterable, Identifiable {
    case apiKey
    case chatGPT
    var id: Self { self }
    var label: String {
        switch self {
        case .apiKey:  return "API Key"
        case .chatGPT: return "ChatGPT 登录"
        }
    }
}

/// 设置窗口的两个选项卡。
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用设置"
    case provider = "模型 / Provider"
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
    private let titleBarInset = SettingsTheme.titleBarInset

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(.white.opacity(SettingsTheme.WhiteAlpha.divider))
            VStack(alignment: .leading, spacing: 16) {
                Text(selectedTab.shortTitle)
                    .font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.textPrimary))
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
        .frame(width: SettingsTheme.windowSize.width, height: SettingsTheme.windowSize.height)
        .background(SettingsTheme.backdrop.ignoresSafeArea())
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
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous)
                    .fill(.white.opacity(SettingsTheme.WhiteAlpha.brandFill))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.glyph)))
                Text("知语设置").font(.headline).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.textPrimary))
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
        .frame(width: SettingsTheme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = (tab == selectedTab)
        return HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 14))
                .frame(width: 18)
                .foregroundStyle(selected ? .white.opacity(SettingsTheme.WhiteAlpha.textPrimary) : .white.opacity(SettingsTheme.WhiteAlpha.iconMuted))
            Text(tab.shortTitle)
                .font(.callout)
                .foregroundStyle(selected ? .white.opacity(SettingsTheme.WhiteAlpha.textPrimary) : .white.opacity(SettingsTheme.WhiteAlpha.textMuted))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous)
            .fill(.white.opacity(selected ? SettingsTheme.WhiteAlpha.rowSelected : 0)))
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = tab }
        .animation(SettingsTheme.rowSelectAnimation, value: selected)
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

    /// 「通用设置」选项卡：触发方式（双击修饰键，默认右 ⌘）+ 新消息自动生成候选。
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
                AccessibilityAuthorizer.openSettings()
            }
            permissionCard(name: "屏幕录制",
                           desc: "识别图片/表情需要；不授权时图片按纯文本处理",
                           granted: vm.screenGranted) {
                ScreenRecordingAuthorizer.openSettings()
            }
        }
    }

    /// 单张权限卡：左侧名称+小字说明，右侧已授权绿点或「去授权」按钮。
    private func permissionCard(name: String, desc: String, granted: Bool,
                                onAuthorize: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.text))
                Text(desc).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                HStack(spacing: 6) {
                    Circle().fill(SettingsTheme.grantedDot).frame(width: 8, height: 8)
                    Text("已授权").font(.callout).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.text))
                }
            } else {
                Button("去授权", action: onAuthorize).buttonStyle(MonoButton(filled: true))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.card, style: .continuous).fill(.white.opacity(SettingsTheme.WhiteAlpha.cardFill)))
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    // MARK: 模型来源 —— 纵向列表 + 单选

    /// 纯 API Key 型的五家（OpenAI 因含 ChatGPT 登录分支单列，见 openAIRow）。
    /// title 取 family.defaultKind.displayName（与 ProviderConfig.name 同源），subtitle/placeholder 逐字保持原样。
    private struct KeyProvider: Identifiable {
        let family: ProviderFamily
        let subtitle: String
        let placeholder: String
        var id: ProviderFamily { family }
        var title: String { family.defaultKind.displayName }
    }

    private static let keyProviders: [KeyProvider] = [
        KeyProvider(family: .deepSeek,  subtitle: "API Key",        placeholder: "DeepSeek API Key"),
        KeyProvider(family: .anthropic, subtitle: "Claude · API Key", placeholder: "Anthropic API Key"),
        KeyProvider(family: .glm,       subtitle: "API Key",        placeholder: "智谱GLM API Key"),
        KeyProvider(family: .kimi,      subtitle: "API Key",        placeholder: "Kimi API Key"),
        KeyProvider(family: .minimax,   subtitle: "API Key",        placeholder: "MiniMax API Key"),
    ]

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("模型来源")
            VStack(spacing: 8) {
                openAIRow
                ForEach(Self.keyProviders) { p in
                    keyRow(family: p.family, title: p.title, subtitle: p.subtitle, placeholder: p.placeholder)
                }
            }
        }
    }

    /// 纯「API Key」型 provider 行：单选卡 + SecureField($vm.apiKey) + 保存。与原 deepSeekRow 等五个一字不差。
    private func keyRow(family: ProviderFamily, title: String, subtitle: String, placeholder: String) -> some View {
        providerCard(selected: vm.family == family, title: title,
                     subtitle: subtitle,
                     onSelect: { vm.family = family }) {
            HStack(spacing: 10) {
                SecureField(placeholder, text: $vm.apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { vm.saveKey() }.buttonStyle(MonoButton(filled: true))
            }
        }
    }

    private var openAIRow: some View {
        providerCard(selected: vm.family == .openAI, title: ProviderFamily.openAI.defaultKind.displayName,
                     subtitle: "API Key 或 ChatGPT 订阅登录",
                     onSelect: { vm.family = .openAI }) {
            monoSegment(options: OpenAIAuthMode.allCases,
                        selected: vm.openAIUsesChatGPT ? .chatGPT : .apiKey) { mode in
                vm.openAIUsesChatGPT = (mode == .chatGPT)
            }
            if vm.openAIUsesChatGPT {
                HStack(spacing: 10) {
                    Label(vm.loggedIn ? "已登录" : "未登录",
                          systemImage: vm.loggedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.callout).foregroundStyle(vm.loggedIn ? .white.opacity(SettingsTheme.WhiteAlpha.text) : .secondary)
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

    @ViewBuilder
    private func providerCard<Content: View>(selected: Bool, title: String, subtitle: String,
                                             onSelect: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? .white.opacity(SettingsTheme.WhiteAlpha.textPrimary) : .white.opacity(SettingsTheme.WhiteAlpha.radioOff))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.textPrimary))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Text("当前启用").font(.caption2).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.textFaint)) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            if selected { content() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.providerCard, style: .continuous)
            .fill(.white.opacity(selected ? SettingsTheme.WhiteAlpha.providerFillOn : SettingsTheme.WhiteAlpha.providerFillOff)))
        .overlay(RoundedRectangle(cornerRadius: SettingsTheme.Radius.providerCard, style: .continuous)
            .stroke(.white.opacity(selected ? SettingsTheme.WhiteAlpha.providerStrokeOn : SettingsTheme.WhiteAlpha.providerStrokeOff), lineWidth: 1))
        .animation(SettingsTheme.providerSelectAnimation, value: selected)
    }

    private func monoSegment(options: [OpenAIAuthMode], selected: OpenAIAuthMode,
                             onSelect: @escaping (OpenAIAuthMode) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(options) { o in
                Button { onSelect(o) } label: {
                    Text(o.label).font(.caption)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(selected == o ? .white : .secondary)
                        .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.segmentItem, style: .continuous)
                            .fill(.white.opacity(selected == o ? SettingsTheme.WhiteAlpha.segmentSelected : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous)
            .fill(.white.opacity(SettingsTheme.WhiteAlpha.segmentTrack)))
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
                .labelsHidden().tint(.white).frame(width: SettingsTheme.pickerWidth)
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
                    .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous).fill(.white.opacity(SettingsTheme.WhiteAlpha.editorFill)))
                    .overlay(RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous).stroke(.white.opacity(SettingsTheme.WhiteAlpha.strokeThin)))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "command").foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.icon))
                    Text("触发快捷键").font(.callout).foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.text))
                    Spacer()
                    Picker("", selection: $vm.triggerKey) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .labelsHidden().tint(.white).frame(width: SettingsTheme.pickerWidth)
                }
                Text("在微信里 \(vm.triggerKey.label) 唤起候选面板。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.card, style: .continuous).fill(.white.opacity(SettingsTheme.WhiteAlpha.cardFill)))

            VStack(alignment: .leading, spacing: 4) {
                Toggle("新消息自动生成候选（切到微信前台时弹出）", isOn: $vm.autoOnNewMessage)
                    .toggleStyle(.switch).tint(.white)
                    .foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.text))
                Text("对方发来新消息时后台预生成；切到微信前台时弹出候选。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsTheme.Radius.card, style: .continuous).fill(.white.opacity(SettingsTheme.WhiteAlpha.cardFill)))
        }
    }
}
