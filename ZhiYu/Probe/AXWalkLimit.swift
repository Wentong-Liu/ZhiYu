import Foundation

/// AX 整树遍历的安全上限（极少触发的护栏，仅防爆栈/爆量；非调参旋钮）。
/// 各处 DFS 护栏统一引用此处常量：这些是行为等价的安全上限，统一到上界不改变正常路径行为。
enum AXWalkLimit {
    /// 单次遍历访问节点数上限。
    static let maxNodes = 9000
    /// 遍历深度上限。
    static let maxDepth = 60
}
