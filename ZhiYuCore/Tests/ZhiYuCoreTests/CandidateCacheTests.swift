import Testing
@testable import ZhiYuCore

@Test func missingKeyReturnsNil() {
    let cache = CandidateCache()
    #expect(cache.candidates(forKey: "nope") == nil)
}

@Test func storedCandidatesAreReturned() {
    let cache = CandidateCache()
    cache.store(["好的", "收到", "马上"], forKey: "k1")
    #expect(cache.candidates(forKey: "k1") == ["好的", "收到", "马上"])
}

@Test func storeOverwritesSameKey() {
    let cache = CandidateCache()
    cache.store(["旧"], forKey: "k1")
    cache.store(["新"], forKey: "k1")
    #expect(cache.candidates(forKey: "k1") == ["新"])
}

@Test func clearEmptiesCache() {
    let cache = CandidateCache()
    cache.store(["x"], forKey: "k1")
    cache.clear()
    #expect(cache.candidates(forKey: "k1") == nil)
}

// (c) 空候选数组 → candidates(forKey:) 返回 nil（视为未命中、会重新生成，防空候选中毒）。
@Test func emptyCandidatesAreTreatedAsMiss() {
    let cache = CandidateCache()
    cache.store([], forKey: "k1")
    #expect(cache.candidates(forKey: "k1") == nil)
}
