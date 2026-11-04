import AppKit

enum TranscriptAttribute {
    /// Int cue id on body text (and the glue after it).
    static let cue = NSAttributedString.Key("lm.cue")
    /// Int paragraph index on the header timestamp.
    static let timestamp = NSAttributedString.Key("lm.timestamp")
}

/// The whole transcript as one attributed string plus range maps (§0, §5.2).
struct TranscriptDocument {
    struct Body {
        /// Location / length of the paragraph body (without the trailing newline).
        let range: NSRange
        /// Folded body text for search, aligned with `range`.
        let folded: [UInt16]
        /// Global start location of each cue's text, ascending.
        let cueLocations: [Int]
        let cueIDs: [Int]
    }

    let attributed: NSAttributedString
    /// Indexed by cue id.
    let cueRanges: [NSRange]
    /// Indexed by paragraph index.
    let bodies: [Body]
    /// Paragraph index for each cue id.
    let paragraphOfCue: [Int]

    /// Cue that owns a global character location inside paragraph `p`.
    func cueID(at location: Int, inParagraph p: Int) -> Int? {
        let body = bodies[p]
        guard !body.cueIDs.isEmpty else { return nil }
        var lo = 0, hi = body.cueLocations.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if body.cueLocations[mid] <= location { lo = mid + 1 } else { hi = mid }
        }
        return body.cueIDs[max(0, lo - 1)]
    }

    /// Range to scroll to for a cue (falls back to its paragraph when the cue text is empty).
    func scrollRange(forCue id: Int) -> NSRange {
        let r = cueRanges[id]
        if r.length > 0 { return r }
        return bodies[paragraphOfCue[id]].range
    }
}

@MainActor
enum TranscriptDocumentBuilder {
    static let bodyFontSize: CGFloat = 15
    static let bodyLineHeight: CGFloat = 26
    static let indent: CGFloat = 30

    static func build(transcript: Transcript, paragraphs: [Paragraph], insertComma: Bool, useHours: Bool) -> TranscriptDocument {
        let out = NSMutableAttributedString()
        let cues = transcript.cues
        var cueRanges = Array(repeating: NSRange(location: 0, length: 0), count: cues.count)
        var paragraphOfCue = Array(repeating: 0, count: cues.count)
        var bodies: [TranscriptDocument.Body] = []

        let bodyFont = NSFont.systemFont(ofSize: bodyFontSize)
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.minimumLineHeight = 24
        headerStyle.maximumLineHeight = 24
        headerStyle.paragraphSpacingBefore = 20
        headerStyle.paragraphSpacing = 2
        let firstHeaderStyle = (headerStyle.mutableCopy() as? NSMutableParagraphStyle) ?? headerStyle
        firstHeaderStyle.paragraphSpacingBefore = 4

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.minimumLineHeight = bodyLineHeight
        bodyStyle.maximumLineHeight = bodyLineHeight
        bodyStyle.firstLineHeadIndent = indent
        bodyStyle.headIndent = indent
        bodyStyle.lineBreakMode = .byWordWrapping

        let natural = NSLayoutManager().defaultLineHeight(for: bodyFont)
        let baseline = max(0, (bodyLineHeight - natural) / 2)

        let headerBaseline = max(0, (24 - NSLayoutManager().defaultLineHeight(for: nameFont)) / 2)

        for (pi, p) in paragraphs.enumerated() {
            // Header: avatar, name, timestamp
            let speaker = transcript.speaker(p.speakerID)
            let name = speaker?.name ?? p.speakerID
            let color = speaker?.colorHex ?? SpeakerPalette.color(at: 0)
            let headerStart = out.length

            let attachment = NSTextAttachment()
            attachment.image = AvatarImageCache.image(name: name, colorHex: color, size: 22)
            attachment.bounds = CGRect(x: 0, y: -6, width: 22, height: 22)
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: " ", attributes: [.font: nameFont, .kern: 4.5]))
            out.append(NSAttributedString(string: name, attributes: [
                .font: nameFont,
                .foregroundColor: Palette.textSecondary,
            ]))
            out.append(NSAttributedString(string: "   ", attributes: [.font: timeFont]))
            out.append(NSAttributedString(string: TimeFormat.timestamp(p.start, hours: useHours), attributes: [
                .font: timeFont,
                .foregroundColor: Palette.textTertiary,
                TranscriptAttribute.timestamp: pi,
                .cursor: NSCursor.pointingHand,
            ]))
            out.append(NSAttributedString(string: "\n", attributes: [.font: nameFont]))
            out.addAttributes([
                .paragraphStyle: pi == 0 ? firstHeaderStyle : headerStyle,
                .baselineOffset: headerBaseline,
            ], range: NSRange(location: headerStart, length: out.length - headerStart))

            // Body: cue texts joined per §9.3
            let bodyStart = out.length
            var locations: [Int] = []
            var previousText: String?
            var previousID: Int?
            var bodyText = ""
            for id in p.cueIDs {
                paragraphOfCue[id] = pi
                let text = cues[id].text
                if text.isEmpty {
                    cueRanges[id] = NSRange(location: out.length, length: 0)
                    locations.append(out.length)
                    continue
                }
                if let prev = previousText, let prevID = previousID {
                    let glue = ParagraphBuilder.separator(previous: prev, next: text, insertComma: insertComma)
                    if !glue.isEmpty {
                        out.append(NSAttributedString(string: glue, attributes: [TranscriptAttribute.cue: prevID]))
                        bodyText += glue
                    }
                }
                let loc = out.length
                out.append(NSAttributedString(string: text, attributes: [TranscriptAttribute.cue: id]))
                cueRanges[id] = NSRange(location: loc, length: out.length - loc)
                bodyText += text
                locations.append(loc)
                previousText = text
                previousID = id
            }
            let bodyEnd = out.length
            var newlineAttrs: [NSAttributedString.Key: Any] = [:]
            if let last = previousID ?? p.cueIDs.last { newlineAttrs[TranscriptAttribute.cue] = last }
            out.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
            out.addAttributes([
                .font: bodyFont,
                .foregroundColor: Palette.textPrimary,
                .paragraphStyle: bodyStyle,
                .baselineOffset: baseline,
            ], range: NSRange(location: bodyStart, length: out.length - bodyStart))

            let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            bodies.append(TranscriptDocument.Body(range: bodyRange, folded: TextFold.fold(bodyText),
                                                  cueLocations: locations, cueIDs: p.cueIDs))
        }

        return TranscriptDocument(attributed: out, cueRanges: cueRanges, bodies: bodies, paragraphOfCue: paragraphOfCue)
    }
}
