import Foundation

/// 进程内候选缓存：key（来自 ContextHasher）-> 候选回复列表。
/// 仅存内存，App 退出即清（符合 spec 隐私要求：不持久化聊天内容）。
public final class CandidateCache: @unchecked Sendable {
    private var storage: [String: [String]] = [:]
    private let lock = NSLock()

    public init() {}

    public func candidates(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func store(_ candidates: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = candidates
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
