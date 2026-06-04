import ZhiYuCore

enum CoreSmokeTest {
    static func sample() -> String {
        let ctx = ChatContext(contactName: "联调", messages: [], draft: "")
        return ContextHasher.key(for: ctx)
    }
}
