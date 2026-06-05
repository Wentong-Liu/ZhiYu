import AppKit
import SwiftUI

/// 候选面板标题栏的拖动把手：只覆盖 header 那一条，让无边框非激活面板可被拖动。
/// 用 `window.performDrag(with:)`（专为无边框窗口设计、拖动时不激活、不抢微信焦点）；
/// 不用 `isMovableByWindowBackground`（会把候选区也变成可拖动）。
/// 仅在悬停时把光标变手型、拖动时变握拳，不加任何可见元素，外观不变。
struct PanelDragHandle: NSViewRepresentable {
    /// 拖动结束（松手）后回调：用于把面板当前位置换算成"相对自动锚点的偏移"并持久化。
    var onMoved: () -> Void
    /// 双击把手重置位置回调。
    var onReset: () -> Void

    func makeNSView(context: Context) -> DragHandleView {
        let v = DragHandleView()
        v.onMoved = onMoved
        v.onReset = onReset
        return v
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.onMoved = onMoved
        nsView.onReset = onReset
    }

    /// 透明、layer-backed 的拖动把手视图。
    final class DragHandleView: NSView {
        var onMoved: () -> Void = {}
        var onReset: () -> Void = {}
        private var trackingAreaRef: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true  // layer-backed、透明，不绘制任何内容
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 { onReset(); return }  // 双击：重置回自动位置
            guard let window = self.window else { return }
            NSCursor.closedHand.set()
            let startMouse = NSEvent.mouseLocation          // 屏幕全局坐标
            let startOrigin = window.frame.origin
            var moved = false
            // 自己抽干拖拽事件直接挪窗口（不经 performDrag/SwiftUI 分发，对非激活无边框面板必定生效）
            while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                if e.type == .leftMouseUp { break }
                let now = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: startOrigin.x + (now.x - startMouse.x),
                                              y: startOrigin.y + (now.y - startMouse.y)))
                moved = true
            }
            NSCursor.openHand.set()
            if moved { onMoved() }                          // 仅真正拖动过才记偏移，纯点击不触发
        }

        // 鼠标在把手上时显示手型；拖动结束/移出时恢复箭头。
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef { removeTrackingArea(existing) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        // 确保标题栏区域内任意点都由本视图接管点击（SwiftUI overlay 透明也能抓到拖动）。
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}
