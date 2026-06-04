import Testing
import Foundation
@testable import ZhiYuCore

@Test func panelSitsAboveComposerInAppKitCoords() {
    // 屏幕高 1000；composer 在 AX 坐标 (x=365, y=734, w=504, h=81)，即距顶 734。
    // composer 顶边的 AppKit y = 1000 - 734 = 266；面板底边应在其上方 gap=8 处 -> originY = 266 + 8 = 274。
    let origin = PanelPositioning.panelOrigin(
        composerAXFrame: CGRect(x: 365, y: 734, width: 504, height: 81),
        screenHeight: 1000, gap: 8)
    #expect(origin.x == 365)
    #expect(origin.y == 274)
}
