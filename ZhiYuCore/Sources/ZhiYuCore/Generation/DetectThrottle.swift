import Foundation

/// 前台高频 AX 通知的硬节流决策（纯函数，便于测试）。
///
/// 背景：微信前台正常使用时，打字停顿/滚动停顿会高频触发 AX 通知。仅靠 0.4s 防抖只能把一串
/// 通知合并成"每个安静窗口跑一次"，但每个窗口仍会付出一整次 ~200ms 的主线程同步快读。
/// 这里在"昂贵读取之前"加最小间隔上限：两次实际读取至少间隔 `minInterval`，避免每个 0.4s
/// 窗口都读。返回"距现在还需等待多久才允许下一次读取"的延迟（≥ debounce）。
public enum DetectThrottle {
    /// 计算下一次读取应延迟的秒数：
    /// - 至少 `debounce`（合并抖动）；
    /// - 且距上次实际读取不早于 `minInterval`。
    /// - Parameters:
    ///   - now: 当前单调时间（如 ProcessInfo.systemUptime）。
    ///   - lastRunAt: 上次实际读取的时间；从未读取传 nil。
    ///   - debounce: 抖动合并窗口（如 0.4s）。
    ///   - minInterval: 两次实际读取的最小间隔（如 1.2s）。
    /// - Returns: 从 now 起应等待的秒数（≥ debounce）。
    public static func delay(now: TimeInterval,
                             lastRunAt: TimeInterval?,
                             debounce: TimeInterval,
                             minInterval: TimeInterval) -> TimeInterval {
        guard let last = lastRunAt else { return debounce }
        let earliest = last + minInterval        // 允许的最早读取时刻
        let waitForInterval = earliest - now      // 还需等多久才到该时刻
        return max(debounce, waitForInterval)
    }
}
