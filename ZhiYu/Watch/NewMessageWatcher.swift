import AppKit
import ApplicationServices
import ZhiYuCore

/// 监听微信新消息（AXObserver，事件驱动非轮询）+ 微信激活（NSWorkspace）。
/// 新消息→防抖+硬节流→交给 CandidatePanelController 决定预生成/展示；微信激活→展示当前会话的新消息候选（兜底，必然可用）。
@MainActor
final class NewMessageWatcher {
    static let shared = NewMessageWatcher()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var debounce: DispatchWorkItem?
    private var activationToken: NSObjectProtocol?

    /// 抖动合并窗口：把一串通知合并成一次评估。
    private static let debounceWindow: TimeInterval = 0.4
    /// 两次实际读取的最小间隔：前台高频通知下，每个安静窗口都跑一整次 ~200ms 同步快读会周期性卡顿；
    /// 这里在昂贵读取之前加硬节流，把读取频率压到 ≥ 此间隔一次。
    private static let minReadInterval: TimeInterval = 1.2
    /// 上次实际触发 autoOnDetect（昂贵快读）的单调时间。
    private var lastDetectAt: TimeInterval?

    func start() {
        if activationToken == nil {
            activationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    // 复用统一身份判定（bundle id + 本地化名兜底），与 WeChatAXProbe.findWeChatApp 同口径。
                    guard WeChatAXProbe.isWeChat(app) else { return }
                    NewMessageWatcher.shared.registerObserverIfNeeded()   // 跟上当前微信 pid（含微信后启动/重启）
                    CandidatePanelController.shared.autoOnActivate()
                }
            }
        }
        registerObserverIfNeeded()
    }

    /// 注册 AX 观察者到微信 application 元素（app 级通知，切会话无需重注册）。
    func registerObserverIfNeeded() {
        guard AXIsProcessTrusted(), let app = WeChatAXProbe.findWeChatApp() else { return }
        let pid = app.processIdentifier
        if observer != nil, observedPID == pid { return }
        teardown()
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notes: [CFString] = [
            kAXCreatedNotification as CFString,
            kAXRowCountChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXLayoutChangedNotification as CFString,
        ]
        for note in notes {
            AXObserverAddNotification(obs, appEl, note, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
    }

    private func teardown() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    /// AX 通知回调（已在主线程）：开关关则忽略；否则防抖+硬节流后交给控制器评估。
    /// 防抖把一串通知合并；硬节流保证两次实际昂贵快读至少间隔 `minReadInterval`，
    /// 避免前台高频通知下每个 0.4s 安静窗口都付出一整次 ~200ms 主线程同步读取。
    fileprivate func onAXNotification() {
        guard AppConfig.shared.autoOnNewMessage else { return }
        debounce?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let delay = DetectThrottle.delay(now: now, lastRunAt: lastDetectAt,
                                         debounce: Self.debounceWindow,
                                         minInterval: Self.minReadInterval)
        let work = DispatchWorkItem { [weak self] in
            self?.lastDetectAt = ProcessInfo.processInfo.systemUptime
            CandidatePanelController.shared.autoOnDetect()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// AXObserver C 回调（无捕获→可转 C 函数指针）。AX 源加在主 runloop，故回调在主线程。
private nonisolated func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                            _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<NewMessageWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.onAXNotification() }
}
