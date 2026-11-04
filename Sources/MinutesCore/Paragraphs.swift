import Foundation

enum ParagraphBuilder {
    static let maxGap: Double = 2.0
    static let maxCharacters = 250

    /// §9.3: same speaker, gap (next start − running max end) < 2 s and paragraph < 250 chars → same paragraph.
    /// `cues` must be sorted by start with `id == index`.
    static func build(cues: [Cue]) -> [Paragraph] {
        var result: [Paragraph] = []
        var speaker: String?
        var ids: [Int] = []
        var start: Double = 0
        var maxEnd: Double = 0
        var chars = 0

        func flush() {
            guard let sp = speaker, !ids.isEmpty else { return }
            result.append(Paragraph(id: result.count, speakerID: sp, cueIDs: ids, start: start, end: maxEnd))
        }

        for cue in cues {
            if let sp = speaker, sp == cue.speakerID, cue.start - maxEnd < maxGap, chars < maxCharacters {
                ids.append(cue.id)
                maxEnd = max(maxEnd, cue.end)
                chars += cue.text.count
            } else {
                flush()
                speaker = cue.speakerID
                ids = [cue.id]
                start = cue.start
                maxEnd = cue.end
                chars = cue.text.count
            }
        }
        flush()
        return result
    }

    /// Glue placed between two cues of one paragraph. CJK text joins directly (plus "，" when the
    /// previous cue has no closing punctuation and `insertComma` is on); other scripts get a space.
    static func separator(previous: String, next: String, insertComma: Bool) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        if last.isCJKLike || first.isCJKLike {
            if insertComma && !last.isPunctuationLike && !first.isPunctuationLike {
                return "，"
            }
            return ""
        }
        if last == " " || first == " " { return "" }
        return " "
    }

    /// Paragraph body as plain text.
    static func text(of paragraph: Paragraph, cues: [Cue], insertComma: Bool) -> String {
        var out = ""
        var previous: String?
        for id in paragraph.cueIDs {
            let t = cues[id].text
            if t.isEmpty { continue }
            if let p = previous { out += separator(previous: p, next: t, insertComma: insertComma) }
            out += t
            previous = t
        }
        return out
    }
}

/// Fast time → cue lookups over start-sorted cues (overlaps allowed).
struct CueTimeline {
    let starts: [Double]
    let ends: [Double]
    /// prefixMaxEnd[i] = max(ends[0...i]); tells whether any cue up to i still covers a time.
    let prefixMaxEnd: [Double]

    init(cues: [Cue]) {
        starts = cues.map(\.start)
        ends = cues.map(\.end)
        var running = -Double.infinity
        var pm: [Double] = []
        pm.reserveCapacity(cues.count)
        for c in cues {
            running = max(running, c.end)
            pm.append(running)
        }
        prefixMaxEnd = pm
    }

    var isEmpty: Bool { starts.isEmpty }

    /// Index of the last cue with start ≤ t.
    func lastStartIndex(atOrBefore t: Double) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// §5.3: the last cue (in start order) with start ≤ t < end; nil inside a gap.
    func activeCue(at t: Double) -> Int? {
        guard var i = lastStartIndex(atOrBefore: t) else { return nil }
        while i >= 0 {
            if prefixMaxEnd[i] <= t { return nil }
            if ends[i] > t { return i }
            i -= 1
        }
        return nil
    }

    /// §3.4: if `t` sits in a gap of at least `threshold` seconds, the start of the next cue.
    func skipTarget(at t: Double, threshold: Double) -> Double? {
        let next: Int
        let gapStart: Double
        if let i = lastStartIndex(atOrBefore: t) {
            if prefixMaxEnd[i] > t { return nil }
            gapStart = prefixMaxEnd[i]
            next = i + 1
        } else {
            gapStart = 0
            next = 0
        }
        guard next < starts.count else { return nil }
        let target = starts[next]
        guard target - gapStart >= threshold, target - t > 0.05 else { return nil }
        return target
    }
}

enum SpeakerStats {
    /// Share of total cue duration per speaker, rounded to whole percent.
    static func percentages(cues: [Cue]) -> [String: Int] {
        var per: [String: Double] = [:]
        var total: Double = 0
        for c in cues {
            per[c.speakerID, default: 0] += c.duration
            total += c.duration
        }
        guard total > 0 else { return per.mapValues { _ in 0 } }
        return per.mapValues { Int(($0 / total * 100).rounded()) }
    }

    /// Merged speaking intervals for one speaker; gaps shorter than `mergeGap` are joined for drawing.
    static func intervals(cues: [Cue], speakerID: String, mergeGap: Double = 0.3) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for c in cues where c.speakerID == speakerID && c.end > c.start {
            if let last = out.last, c.start <= last.upperBound + mergeGap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, c.end)
            } else {
                out.append(c.start...c.end)
            }
        }
        return out
    }
}
