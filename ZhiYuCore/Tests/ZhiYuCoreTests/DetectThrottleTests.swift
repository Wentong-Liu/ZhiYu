import Testing
@testable import ZhiYuCore

@Suite struct DetectThrottleTests {
    @Test func firstRunWaitsOnlyDebounce() {
        // 从未读取过：只等防抖窗口。
        let d = DetectThrottle.delay(now: 100, lastRunAt: nil, debounce: 0.4, minInterval: 1.2)
        #expect(d == 0.4)
    }

    @Test func soonAfterLastRunWaitsForMinInterval() {
        // 上次读取在 0.2s 前：距最小间隔(1.2s)还差 1.0s，应等 1.0s（> 防抖 0.4s）。
        let d = DetectThrottle.delay(now: 100.2, lastRunAt: 100.0, debounce: 0.4, minInterval: 1.2)
        #expect(abs(d - 1.0) < 1e-9)
    }

    @Test func longAfterLastRunWaitsOnlyDebounce() {
        // 上次读取在 5s 前：早已过最小间隔，只等防抖 0.4s。
        let d = DetectThrottle.delay(now: 105.0, lastRunAt: 100.0, debounce: 0.4, minInterval: 1.2)
        #expect(d == 0.4)
    }

    @Test func neverReturnsLessThanDebounce() {
        // 即便刚过最小间隔一点点，也不会低于防抖窗口。
        let d = DetectThrottle.delay(now: 101.21, lastRunAt: 100.0, debounce: 0.4, minInterval: 1.2)
        #expect(d == 0.4)
    }

    @Test func exactlyAtMinIntervalWaitsDebounce() {
        // 恰好到最小间隔边界：waitForInterval=0，取防抖。
        let d = DetectThrottle.delay(now: 101.2, lastRunAt: 100.0, debounce: 0.4, minInterval: 1.2)
        #expect(d == 0.4)
    }
}
