import Foundation

/// 把对话上下文 + 风格 + 候选数量组装成发给模型的消息。
/// 支持"多气泡"：对方连发多条时，回复也用相近数量的简短消息，每条候选内部用换行分隔。
public enum PromptBuilder {
    public static func build(context: ChatContext, style: ReplyStyle, candidateCount: Int) -> [LLMMessage] {
        let trailing = MessageRhythm.trailingOtherCount(context.messages)
        let rhythm: String
        if trailing >= 2 {
            rhythm = "对方最近连发了 \(trailing) 条消息。请用相近数量（约 \(trailing) 条）的简短消息回应，"
                + "模仿对方的长度与节奏，不要把多句挤成一长段；"
                + "每条候选内部用换行符 \\n 分隔这些小消息（发送时会拆成多条单独发出）。"
        } else {
            rhythm = "对方最近只发了一条，正常回一条即可（不需要换行拆分）。"
        }
        let system = """
        你在帮"我"快速回复微信聊天。请基于下面的对话，站在"我"的角度生成 \(candidateCount) 条候选回复。
        风格要求：\(style.instruction)
        \(rhythm)
        必须用对话所用语言回复（对方用中文就用中文）。回复要像真人微信聊天，自然、简短。
        只返回一个 JSON 数组，含 \(candidateCount) 条候选；每条是一个字符串（多条小消息用 \\n 分隔）。
        不要任何额外解释或编号。例如：["在的\\n咋了","哈哈笑死\\n你太逗了\\n等我会儿"]
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
