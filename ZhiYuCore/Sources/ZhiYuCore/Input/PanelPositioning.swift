import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// AX(左上原点) 的 composer frame 换算为 AppKit(左下原点) 的面板左下角原点，使面板贴在 composer 上方。
public enum PanelPositioning {
    /// - Parameters:
    ///   - composerAXFrame: AX 坐标系下输入框 frame（y 为距屏幕顶部的距离）。
    ///   - screenHeight: 该输入框所在屏幕的高度（点）。
    ///   - gap: 面板底边与 composer 顶边的间隙。
    /// - Returns: AppKit 坐标系（左下原点）下面板的左下角原点。
    public static func panelOrigin(composerAXFrame: CGRect, screenHeight: CGFloat,
                                   gap: CGFloat) -> CGPoint {
        let composerTopAppKit = screenHeight - composerAXFrame.minY
        return CGPoint(x: composerAXFrame.minX, y: composerTopAppKit + gap)
    }
}
