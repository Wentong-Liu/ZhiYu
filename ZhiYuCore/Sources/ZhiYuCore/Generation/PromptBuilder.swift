import Foundation

/// 把对话上下文 + 风格 + 候选数量组装成发给模型的消息。
public enum PromptBuilder {
    public static func build(context: ChatContext, style: ReplyStyle, candidateCount: Int) -> [LLMMessage] {
        let system = """
        你在帮"我"快速回复微信聊天。请基于下面的对话，站在"我"的角度生成 \(candidateCount) 条候选回复。
        风格要求：\(style.instruction)
        必须用对话所用语言回复（对方用中文就用中文）。回复要像真人微信聊天，自然、简短。
        只返回一个 JSON 数组，元素是 \(candidateCount) 条候选回复字符串，不要任何额外解释或编号。
        例如：["好的","稍等我看看","马上到"]
        """
        var convo = "对话（按时间顺序）：\n"
        for m in context.messages {
            let who = m.speaker == .me ? "我" : "对方"
            convo += "\(who): \(m.text)\n"
        }
        if !context.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            convo += "\n我已经打了草稿：「\(context.draft)」。请在此基础上续写/润色，生成候选。\n"
        }
        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: convo),
        ]
    }
}
