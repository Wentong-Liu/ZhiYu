import SwiftUI

/// 设置窗口的设计 token 集中点（颜色 / 圆角 / 尺寸 / 不透明度）。
/// 这里的数值逐一对应原先散落在 `SettingsView` 里的硬编码，**值不变**，仅做集中复用。
enum SettingsTheme {

    // MARK: 窗口与布局尺寸

    /// 设置窗口固定尺寸。
    static let windowSize = CGSize(width: 720, height: 600)
    /// 隐藏系统标题栏后为顶部红绿灯/标题预留的高度。
    static let titleBarInset: CGFloat = 32
    /// 左侧导航栏宽度。
    static let sidebarWidth: CGFloat = 200
    /// 模型/触发器右侧 Picker 的固定宽度。
    static let pickerWidth: CGFloat = 130

    // MARK: 颜色

    /// 整窗深色背板。
    static let backdrop = Color(red: 0.10, green: 0.10, blue: 0.11)
    /// 已授权状态指示绿点。
    static let grantedDot = Color.green

    // MARK: 圆角

    /// 各类圆角半径（与原硬编码一一对应）。
    enum Radius {
        /// 分段控件内单格选中底。
        static let segmentItem: CGFloat = 6
        /// 按钮 / 输入框 / 分段控件外框 / 品牌图标等通用圆角。
        static let control: CGFloat = 8
        /// 卡片（权限卡、触发卡）圆角。
        static let card: CGFloat = 10
        /// Provider 卡片圆角。
        static let providerCard: CGFloat = 12
    }

    // MARK: 白色叠加不透明度

    /// 统一管理 `.white.opacity(...)` 的各档透明度（值与原代码逐一对应）。
    enum WhiteAlpha {
        // 文字层级
        /// 主文字（卡片标题、品牌名、选中态等）。
        static let textPrimary: Double = 0.95
        /// 次主文字（按钮前景、模型按钮主操作前景）。
        static let textStrong: Double = 0.92
        /// 普通正文文字（名称、说明、已授权文案）。
        static let text: Double = 0.9
        /// 图标常态前景（如 command 图标）。
        static let icon: Double = 0.8
        /// 品牌图标内字形。
        static let glyph: Double = 0.85
        /// 次要选中文字（侧栏未选中文字）。
        static let textMuted: Double = 0.7
        /// 「当前启用」角标文字。
        static let textFaint: Double = 0.55
        /// 侧栏未选中图标。
        static let iconMuted: Double = 0.55
        /// Provider 未选中单选圈。
        static let radioOff: Double = 0.35

        // 描边
        /// 按钮 / 自定义输入框等细描边。
        static let strokeThin: Double = 0.1
        /// 分隔线叠加。
        static let divider: Double = 0.08
        /// Provider 卡片选中描边。
        static let providerStrokeOn: Double = 0.18
        /// Provider 卡片未选中描边。
        static let providerStrokeOff: Double = 0.06

        // 填充背板
        /// 品牌图标底。
        static let brandFill: Double = 0.12
        /// 侧栏选中行底。
        static let rowSelected: Double = 0.1
        /// 分段控件选中单格底。
        static let segmentSelected: Double = 0.16
        /// 分段控件外框底。
        static let segmentTrack: Double = 0.05
        /// 卡片（权限/触发）底。
        static let cardFill: Double = 0.05
        /// 自定义提示词输入框底。
        static let editorFill: Double = 0.06
        /// Provider 卡片选中底。
        static let providerFillOn: Double = 0.07
        /// Provider 卡片未选中底。
        static let providerFillOff: Double = 0.025

        // MonoButton 底（主/次 × 常态/按下）
        /// 主按钮按下态底。
        static let buttonFilledPressed: Double = 0.26
        /// 主按钮常态底。
        static let buttonFilled: Double = 0.18
        /// 次按钮按下态底。
        static let buttonPlainPressed: Double = 0.12
        /// 次按钮常态底。
        static let buttonPlain: Double = 0.06
    }

    // MARK: 动画

    /// 侧栏选中切换动画。
    static let rowSelectAnimation = Animation.easeOut(duration: 0.14)
    /// Provider 卡片选中切换动画。
    static let providerSelectAnimation = Animation.easeOut(duration: 0.16)
}

/// 黑白灰按钮：filled=true 为主操作（稍亮的灰底），否则次级（更淡）。
struct MonoButton: ButtonStyle {
    var filled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let fillAlpha: Double = filled
            ? (configuration.isPressed ? SettingsTheme.WhiteAlpha.buttonFilledPressed : SettingsTheme.WhiteAlpha.buttonFilled)
            : (configuration.isPressed ? SettingsTheme.WhiteAlpha.buttonPlainPressed : SettingsTheme.WhiteAlpha.buttonPlain)
        return configuration.label
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(.white.opacity(SettingsTheme.WhiteAlpha.textStrong))
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous)
                    .fill(.white.opacity(fillAlpha))
            )
            .overlay(RoundedRectangle(cornerRadius: SettingsTheme.Radius.control, style: .continuous)
                .stroke(.white.opacity(SettingsTheme.WhiteAlpha.strokeThin)))
    }
}
