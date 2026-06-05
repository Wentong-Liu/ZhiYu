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

// 可见区：原点 (0,0)、宽 1440、高 900；面板 size 400x300，故 x∈[0,1040]、y∈[0,600]。
private let clampVF = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let clampSize = CGSize(width: 400, height: 300)

@Test func clampedWithZeroOffsetOnlyClamps() {
    // offset 为零且 base 在可见区内：原样返回（只夹紧、不平移）。
    let p = PanelPositioning.clamped(origin: CGPoint(x: 200, y: 150), offset: .zero,
                                     size: clampSize, within: clampVF)
    #expect(p.x == 200)
    #expect(p.y == 150)
}

@Test func clampedAppliesPositiveOffset() {
    // 正偏移在可见区内：base + offset 生效。
    let p = PanelPositioning.clamped(origin: CGPoint(x: 200, y: 150),
                                     offset: CGSize(width: 30, height: 40),
                                     size: clampSize, within: clampVF)
    #expect(p.x == 230)
    #expect(p.y == 190)
}

@Test func clampedClampsRightAndTopOverflow() {
    // 超出右/上边界：x 夹到 maxX-width=1040，y 夹到 maxY-height=600。
    let p = PanelPositioning.clamped(origin: CGPoint(x: 1300, y: 800),
                                     offset: CGSize(width: 500, height: 500),
                                     size: clampSize, within: clampVF)
    #expect(p.x == 1040)
    #expect(p.y == 600)
}

@Test func clampedClampsLeftAndBottomOverflow() {
    // 超出左/下边界：x 夹到 minX=0，y 夹到 minY=0。
    let p = PanelPositioning.clamped(origin: CGPoint(x: 50, y: 50),
                                     offset: CGSize(width: -500, height: -500),
                                     size: clampSize, within: clampVF)
    #expect(p.x == 0)
    #expect(p.y == 0)
}
