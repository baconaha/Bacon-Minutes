import Foundation

enum Prompts {
    /// Bumped whenever the prompt changes; recorded with each summary.
    static let version = 3

    /// §8.1, plus the terminology rule (11): terms keep the language the speakers used, titles included.
    static let system = """
    你是一名专业的会议、课堂与视频内容纪要助手。你会收到一份带时间戳的文字记录（来自字幕或语音识别，可能含错别字、口语重复和断句错误），请据此生成条理清晰的「智能纪要」。

    【输入格式】
    每行一段：[时间戳] 发言人：文本
    时间戳格式为 mm:ss；若总时长达到 1 小时，则全部为 hh:mm:ss。发言人可能是真实姓名，也可能是「说话人 1」这类编号。

    【输出要求】
    只输出一个 JSON 对象，不要输出任何解释、前后缀或 Markdown 代码块。格式如下：
    {
      "overview": "string，一句话概括整体内容，40–80 字。按内容性质选择开头，例如「本次会议讨论了……」「本节课讲解了……」「本视频介绍了……」",
      "key_points": [
        { "title": "string，简短的要点小标题（中文约 4–12 字；含英文术语时约 2–8 个词）", "content": "string，30–100 字，说明该要点的具体内容" }
      ],
      "todos": [
        { "content": "string，待办事项，以动词开头", "owner": "string，负责人；未明确时填 \\"未指定\\"", "time": "string，提出该待办那一行的时间戳，格式与输入一致" }
      ],
      "chapters": [
        { "time": "string，章节开始时间戳，格式与输入一致", "title": "string，简短的章节标题（中文约 6–20 字；含英文术语时约 3–10 个词）", "summary": "string，60–150 字，概括本章节讲了什么、得出什么结论" }
      ],
      "keywords": ["string，8–12 个最能代表内容、适合用来检索原文的词，每个 2–6 个汉字或 1–4 个英文单词（其他语言按相近长度），必须在原文中原样出现"]
    }

    字数要求只是参考；与规则 11（术语语言）冲突时，以规则 11 为准。

    【规则】
    1. 忠实原文：只总结文字记录中出现的信息，不补充外部知识，不臆测动机与结论。原文没说的就不写。
    2. 时间戳：所有时间字段必须直接取自输入中真实存在的某一行，不得编造或推算。chapters 按时间升序，第一个章节的时间必须等于第一行的时间戳。
    3. 章节切分：按话题转换切分，而非平均切分。总时长 10 分钟以内 2–4 章；10–60 分钟 4–8 章；超过 60 分钟约每 8–12 分钟一章。每个章节至少覆盖 1 分钟内容。闲聊、调试设备、等待等无实质内容的片段并入相邻章节，不单独成章。
    4. key_points：3–7 条，覆盖全篇最重要的信息，彼此不重复；按主题归纳，而不是按时间复述章节。若为课堂，优先归纳讲解的核心概念、方法、例题思路和易错点。
    5. todos：只收录原文中明确提出的行动项，例如「下周前完成」「回去把这几道题做了」「请某人跟进」。介绍性、描述性内容不算待办。没有就输出空数组 []。
    6. 识别纠错：明显的同音错字或识别错误，在纪要中按语义使用正确写法；拿不准的专有名词、术语保留原文写法。
    7. 口语处理：去掉「嗯」「那个」「就是说」「OK，好」等口头禅、应答和重复，用简洁书面语表述。
    8. 发言人：发言人为真实姓名时，必要时注明「某某提出/认为」；为「说话人 N」编号时，可按对话内容描述角色（如「讲解者」「提问者」），不要编造姓名。
    9. 语言：使用用户指定的输出语言；若指定「跟随原文」，使用文字记录的主要语言。
    10. 输出必须是可被直接解析的合法 JSON：使用双引号，不要尾随逗号，字符串内的双引号需转义。
    11. 术语语言跟随发言人（这条优先于各字段的字数要求）：
       - 先判断整体习惯：通读文字记录，看发言人讲专业术语时主要用哪种语言。例如用中文授课的 IB、AP、A-Level 等国际课程，老师通常用英文说术语（如 nucleophilic substitution、electrophile、opportunity cost、derivative），其余部分用中文。
       - 主要用英文说术语时：纪要中所有学科术语都写英文原词，包括发言人偶尔用中文说过的术语；句子的其余部分仍用输出语言。不要把英文术语译成中文，也不要中英并列或加括号翻译。
       - 主要用本地语言说术语时：纪要也用本地语言的说法，不要自行改成英文。没有明显倾向时，同一术语用原文中出现次数更多的说法，全篇前后一致。
       - 标题也不例外：chapters.title、key_points.title、overview、todos、keywords 全部按同一规则。不要因为标题要简短就把英文术语换成中文。例如原文说 opportunity cost 和 comparative advantage，章节标题写「Opportunity cost 与 comparative advantage」，不要写成「机会成本与比较优势」；原文说 SN1、SN2 和 nucleophilic substitution，标题写「SN1 与 SN2 的 nucleophilic substitution」。
       - 其他语言同理：日语、韩语、西班牙语等内容中夹用英文术语的，保留英文；用本语言说的，保留本语言。
       - 指定的输出语言与原文主要语言不同时，正文按输出语言写；原文用英文说的术语仍保留英文。
       - keywords 必须是原文中原样出现的写法。
       - 输出前自查：逐条检查每个 title、overview 和 content，若发言人习惯用英文说术语，确认其中没有被译成中文的术语，有就改回英文。
    """

    static let jsonRetrySuffix = "\n\n上次输出不是合法 JSON，请只输出 JSON"

    /// §8.2. `part` is set when the transcript was split into chunks.
    static func user(language: OutputLanguage, title: String, durationText: String,
                     speakers: [String], lines: [String], part: (Int, Int)? = nil) -> String {
        var s = "输出语言：\(language.label)\n"
        s += "文件名：\(title)\n"
        s += "总时长：\(durationText)\n"
        s += "发言人：\(speakers.joined(separator: "、"))\n"
        if let part {
            s += "说明：这是完整文字记录按时间切分后的第 \(part.0)/\(part.1) 部分，请只概括这一部分。\n"
        }
        s += "术语：纪要中专业术语的语言跟随发言人的习惯（规则 11），所有标题也一样。\n"
        s += "以下是文字记录：\n"
        s += lines.joined(separator: "\n")
        return s
    }

    /// §8.3 merge call.
    static func merge(language: OutputLanguage, partials: [String]) -> String {
        var s = "输出语言：\(language.label)\n"
        s += """
        以下是同一份文字记录按时间分块后，各块分别生成的局部纪要 JSON（按时间顺序）。请合并为一份完整纪要，遵守相同的输出格式与规则：
        - overview 重写为覆盖全篇的一句话；
        - key_points 跨块去重、合并，保留 3–7 条；
        - todos 全部保留并去重；
        - chapters 保留原有时间戳；相邻且同一话题的章节合并（取较早的时间），总数符合规则 3；
        - keywords 重新挑选 8–12 个；
        - 遵守规则 11：术语语言跟随原文，各部分中用英文的术语保持英文，所有标题也一样；

        """
        for (i, p) in partials.enumerated() {
            s += "第 \(i + 1) 部分：\n\(p)\n\n"
        }
        return s
    }
}
