import Foundation

/// 把对话上下文 + 风格 + 候选数量组装成发给模型的消息。
/// 支持"多气泡"：对方连发多条时，回复也用相近数量的简短消息，每条候选内部用换行分隔。
public enum PromptBuilder {
    public static func build(context: ChatContext, style: ReplyStyle, candidateCount: Int) -> [LLMMessage] {
        let trailing = MessageRhythm.trailingOtherCount(context.messages)
        let rhythm: String
        if trailing >= MessageRhythm.multiBubbleThreshold {
            // 「\n 分隔的小消息」契约：发送时由 BubbleSplitter.split 按换行拆成多条气泡。
            // 若此处改换行约定（分隔符/拆分规则），必须同步改 BubbleSplitter。
            rhythm = "对方最近连发了 \(trailing) 条消息。请用相近数量（约 \(trailing) 条）的简短消息回应，"
                + "模仿对方的长度与节奏，不要把多句挤成一长段；"
                + "每条候选内部用换行符 \\n 分隔这些小消息（发送时会拆成多条单独发出）。"
        } else {
            rhythm = "对方最近只发了一条，正常回一条即可（不需要换行拆分）。"
        }
        // 下面的 system prompt 定义了三条「输出契约」，解析端各有对应实现，改文案务必同步：
        //   1) JSON 数组输出（"只返回一个 JSON 数组…"）          → CandidateParser.parse / parseJSONArray
        //   2) 多条小消息用换行符 \n 分隔（示例 "在的\n咋了"）      → BubbleSplitter.split
        //   3) 表情提示行另起一行写「表情: 关键词」                → CandidateParser.parseSticker（前缀同 stickerPrefix）
        let system = """
        你在帮"我"回微信，目标是让回复像"我"本人随手打的，而不是 AI 生成的。像跟熟人聊天，不是客服。
        先根据对话判断"我"和对方的关系与熟络程度（哥们/对象/家人/同事/客户/刚认识…），用匹配这段关系的语气和分寸来回。
        仔细模仿"我"在历史里发过的消息：用词、句子长度、标点习惯、爱用的语气词和口头禅，让候选就是"我"的腔调，而不是模板。
        像真人发微信：
        - 短。能一个词或一句说完就别凑成段（"嗯""行""好""草""哈哈哈""在呢""真的假的"都可以）。
        - 句尾一般不打句号，逗号能省就省，口语化、可省略主语，不用追求语法完整。
        - 自然用语气词和网络词（啊/呀/嘛/哦/欸/吧/咯；哈哈哈、卧槽、绝了、离谱、笑死 之类，按关系和场合用，正式场合就别用）。
        - 别面面俱到地回应每句，挑最该回的回，可以反问、调侃、吐槽、甚至敷衍。
        - emoji 和颜文字少而精，别每句都加。
        - 几条候选之间语气和长度要有差别，别一个模子刻的。
        绝对不要（一眼就是机器人）：客服腔和万能热情（"好的呀~""没问题哦""亲""有什么需要随时跟我说""很高兴帮到你"）；总结腔、说明文腔、"作为…""我可以帮你…""首先…其次…"；每句都工整标点、句尾都打句号、用破折号；过度礼貌、过度热情、端着。

        请基于下面的对话，站在"我"的角度生成 \(candidateCount) 条候选回复。
        额外风格倾向：\(style.instruction)
        \(rhythm)
        必须用对话所用语言回复（对方用中文就用中文）。
        只返回一个 JSON 数组，含 \(candidateCount) 条候选；每条是一个字符串（多条小消息用 \\n 分隔）。
        不要任何额外解释或编号。例如：["在的\\n咋了","哈哈笑死\\n你太逗了\\n等我会儿"]
        此外：若此刻用一个表情包回应会更自然，可在 JSON 数组之后【另起一行】写「表情: 关键词」（关键词用中文、1-4 字，会用于在微信表情里搜索，如 报警、笑死、无语、好的、爱你、晚安）。多数情况普通文字即可，不必每次都给；不合适就不要这一行，也不要把它写进 JSON 数组里。
        """
        var convo = "对话（按时间顺序）：\n"
        for m in context.messages {
            let who = m.speaker == .me ? "我" : "对方"
            convo += "\(who): \(m.text)\n"
        }
        if !context.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            convo += "\n我已经打了草稿：「\(context.draft)」。请在此基础上续写/润色，生成候选。\n"
        }
        let hasImages = !context.imageDataURLs.isEmpty
        let convoText = convo + (hasImages ? "\n（对方还发了图片/表情，见附带的图像，请结合图像内容回复。）\n" : "")
        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: convoText, imageDataURLs: context.imageDataURLs),
        ]
    }
}
