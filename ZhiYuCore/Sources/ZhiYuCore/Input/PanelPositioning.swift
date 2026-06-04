import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// AX(左上原点) 的 composer frame 换算为 AppKit(左下原点) 的面板左下角原点，使面板贴在 composer 上方。
public enum PanelPositioning {
    /// AX/CG 全局坐标与 AppKit 全局坐标共享同一个全局平面，仅 y 轴方向相反：
    /// 两者的原点都锚定在主显示器（含全局原点的屏，AppKit frame.origin == (0,0)）。
    /// AX 原点在主屏左上、y 向下；AppKit 原点在主屏左下、y 向上。
    /// 因此换算为 `appKitY = primaryScreenHeight - axY`，是一个与点落在哪块屏无关的全局变换——
    /// 副屏的 frame 偏移已隐含在 AX 的全局 y 里，无需再叠加目标屏高度或偏移。
    /// 换算得到的 x（AX 全局，原点同样在主屏左缘）即 AppKit 全局 x，副屏的水平偏移也已隐含其中。
    /// - Parameters:
    ///   - composerAXFrame: AX 全局坐标系下输入框 frame（y 为距主屏顶部的距离）。
    ///   - primaryScreenHeight: 主显示器（含全局原点的屏）的高度（点）；用于全局 y 翻转。
    ///   - gap: 面板底边与 composer 顶边的间隙。
    /// - Returns: AppKit 全局坐标系（主屏左下原点）下面板的左下角原点。
    public static func panelOrigin(composerAXFrame: CGRect, primaryScreenHeight: CGFloat,
                                   gap: CGFloat) -> CGPoint {
        let composerTopAppKit = primaryScreenHeight - composerAXFrame.minY
        return CGPoint(x: composerAXFrame.minX, y: composerTopAppKit + gap)
    }
}
