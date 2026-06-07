import Testing
import Foundation
@testable import ZhiYuCore

/// 测试用双击阈值（与 ModifierDoubleTap.doubleTapThreshold 同值 0.4；跨模块无法直接共享 App 内常量，故就近定义）。
private let doubleTapThreshold: TimeInterval = 0.4

@Test func twoPressesWithinThresholdIsDoubleTap() {
    var d = DoubleTapDetector(threshold: doubleTapThreshold)
    #expect(d.registerPress(at: 1.00) == false)
    #expect(d.registerPress(at: 1.30) == true)   // 间隔 0.30 < 0.4
}

@Test func twoPressesTooFarApartIsNotDoubleTap() {
    var d = DoubleTapDetector(threshold: doubleTapThreshold)
    #expect(d.registerPress(at: 1.00) == false)
    #expect(d.registerPress(at: 1.90) == false)  // 间隔 0.90 > 0.4，重置为新的首击
    #expect(d.registerPress(at: 2.10) == true)   // 与上一次间隔 0.20
}

@Test func resetClearsPendingFirstPress() {
    var d = DoubleTapDetector(threshold: doubleTapThreshold)
    _ = d.registerPress(at: 1.00)
    d.reset()
    #expect(d.registerPress(at: 1.20) == false)  // 已重置，这是新的首击
}
