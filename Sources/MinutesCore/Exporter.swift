import Foundation

enum Exporter {
    /// SRT with current speaker names as `名字: ` prefixes.
    static func srt(transcript: Transcript) -> String {
        var out = ""
        for (i, cue) in transcript.cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(TimeFormat.srtTimestamp(cue.start)) --> \(TimeFormat.srtTimestamp(cue.end))\n"
            out += "\(transcript.speakerName(cue.speakerID)): \(cue.text)\n\n"
        }
        return out
    }

    /// Plain text: one block per paragraph with speaker and timestamp.
    static func txt(transcript: Transcript, paragraphs: [Paragraph], insertComma: Bool, useHours: Bool) -> String {
        var out = ""
        for p in paragraphs {
            let body = ParagraphBuilder.text(of: p, cues: transcript.cues, insertComma: insertComma)
            out += "\(transcript.speakerName(p.speakerID))  \(TimeFormat.timestamp(p.start, hours: useHours))\n"
            out += body + "\n\n"
        }
        return out
    }

    static func summaryMarkdown(_ s: Summary, useHours: Bool, headingLevel: Int = 2) -> String {
        let h = String(repeating: "#", count: headingLevel)
        var out = "\(h) 会议纪要\n\n"
        if !s.overview.isEmpty { out += s.overview + "\n\n" }
        for kp in s.keyPoints {
            out += "- **\(kp.title)**：\(kp.content)\n"
        }
        if !s.keyPoints.isEmpty { out += "\n" }
        out += "\(h)# 待办\n\n"
        if s.todos.isEmpty {
            out += "本场会议无待办内容\n\n"
        } else {
            for t in s.todos {
                out += "- [ ] \(t.content) · \(t.owner) · \(TimeFormat.timestamp(t.time, hours: useHours))\n"
            }
            out += "\n"
        }
        out += "\(h) 章节纪要\n\n"
        for c in s.chapters {
            out += "\(h)# \(TimeFormat.timestamp(c.time, hours: useHours)) \(c.title)\n\n\(c.summary)\n\n"
        }
        if !s.keywords.isEmpty {
            out += "\(h) 关键词\n\n" + s.keywords.joined(separator: "、") + "\n\n"
        }
        out += "> 智能纪要由 AI 生成，请谨慎使用\n"
        return out
    }

    static func markdown(title: String, createdAt: Date, duration: Double, summary: Summary?,
                         transcript: Transcript?, paragraphs: [Paragraph], insertComma: Bool) -> String {
        let useHours = TimeFormat.usesHours(totalDuration: duration)
        var out = "# \(title)\n\n"
        out += "\(TimeFormat.createdDate(createdAt)) · \(TimeFormat.durationCN(duration))\n\n"
        if let summary {
            out += "## 智能纪要\n\n"
            out += summaryMarkdown(summary, useHours: useHours, headingLevel: 3)
            out += "\n"
        }
        if let transcript {
            out += "## 文字记录\n\n"
            for p in paragraphs {
                let body = ParagraphBuilder.text(of: p, cues: transcript.cues, insertComma: insertComma)
                out += "**\(transcript.speakerName(p.speakerID))** `\(TimeFormat.timestamp(p.start, hours: useHours))`\n\n"
                out += body + "\n\n"
            }
        }
        return out
    }
}
