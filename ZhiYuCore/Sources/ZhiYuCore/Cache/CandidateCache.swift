import Foundation

/// 进程内候选缓存：key（来自 ContextHasher）-> 候选回复列表。
/// 仅存内存，App 退出即清（符合 spec 隐私要求：不持久化聊天内容）。
public final class CandidateCache: @unchecked Sendable {
    private var storage: [String: [String]] = [:]
    private var stickerStorage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func candidates(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        // 空数组视为未命中（防空候选中毒：解析失败时存了 []，否则该 context 会永久命中空结果而不再重生成）。
        // 与 stickerStorage 的 !isEmpty 守卫对称。
        guard let stored = storage[key], !stored.isEmpty else { return nil }
        return stored
    }

    public func store(_ candidates: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = candidates
    }

    public func stickerKeyword(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stickerStorage[key]
    }

    public func storeSticker(_ keyword: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let k = keyword, !k.isEmpty { stickerStorage[key] = k } else { stickerStorage[key] = nil }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        stickerStorage.removeAll()
    }
}
