import Testing
import Foundation
@testable import ZhiYuCore

@Test func panelSitsAboveComposerInAppKitCoords() {
    // 主屏高 1000；composer 在 AX 全局坐标 (x=365, y=734, w=504, h=81)，即距主屏顶 734。
    // composer 顶边的 AppKit y = 1000 - 734 = 266；面板底边应在其上方 gap=8 处 -> originY = 266 + 8 = 274。
    let origin = PanelPositioning.panelOrigin(
        composerAXFrame: CGRect(x: 365, y: 734, width: 504, height: 81),
        primaryScreenHeight: 1000, gap: 8)
    #expect(origin.x == 365)
    #expect(origin.y == 274)
}

@Test func panelOriginUsesPrimaryHeightRegardlessOfTargetScreen() {
    // 副屏场景：composer 落在主屏下方的副屏上，AX 全局 y 已包含副屏偏移（如 y=1400）。
    // 换算只依赖主屏高度（1000）：appKitTop = 1000 - 1400 = -400（主屏坐标系下方，正确表达副屏）。
    // panelOriginY = -400 + 8 = -392。这是全局 AppKit y，后续夹取用目标屏 frame 完成。
    let origin = PanelPositioning.panelOrigin(
        composerAXFrame: CGRect(x: 100, y: 1400, width: 504, height: 81),
        primaryScreenHeight: 1000, gap: 8)
    #expect(origin.x == 100)
    #expect(origin.y == -392)
}
