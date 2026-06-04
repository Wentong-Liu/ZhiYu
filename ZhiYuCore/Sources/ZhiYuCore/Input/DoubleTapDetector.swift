import Foundation

/// 双击判定：连续两次"按下"间隔不超过 threshold 即为双击。中间被 reset() 打断则重新计。
public struct DoubleTapDetector: Sendable {
    public let threshold: TimeInterval
    private var lastPress: TimeInterval?

    public init(threshold: TimeInterval = 0.4) {
        self.threshold = threshold
    }

    /// 传入本次按下的时间戳（秒，单调递增即可，如 NSEvent.timestamp）。返回是否构成双击。
    public mutating func registerPress(at time: TimeInterval) -> Bool {
        if let last = lastPress, time - last <= threshold {
            lastPress = nil
            return true
        }
        lastPress = time
        return false
    }

    /// 中间夹了别的键 / 需要打断时调用。
    public mutating func reset() { lastPress = nil }
}
