import Foundation

enum TimeFormat {
    static func usesHours(totalDuration: Double) -> Bool { totalDuration >= 3600 }

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private static func wholeSeconds(_ t: Double) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        return Int(t)
    }

    /// Player / transcript timestamp: `mm:ss`, or `hh:mm:ss` when the media is an hour or longer.
    static func timestamp(_ t: Double, hours: Bool) -> String {
        let total = wholeSeconds(t)
        let s = total % 60
        if hours {
            return "\(pad2(total / 3600)):\(pad2((total % 3600) / 60)):\(pad2(s))"
        }
        return "\(pad2(total / 60)):\(pad2(s))"
    }

    /// Hour / minute / second words and spacing for long durations.
    private struct Units {
        let h: String, m: String, s: String
        /// Between the number and its unit.
        let gap: String
        /// Between the parts.
        let joiner: String
    }

    private static func units(_ lang: AppLanguage) -> Units {
        switch lang {
        case .zhHans: return Units(h: "小时", m: "分", s: "秒", gap: " ", joiner: " ")
        case .en: return Units(h: "h", m: "m", s: "s", gap: "", joiner: " ")
        case .ja: return Units(h: "時間", m: "分", s: "秒", gap: "", joiner: "")
        case .ko: return Units(h: "시간", m: "분", s: "초", gap: "", joiner: " ")
        case .es, .pt, .fr: return Units(h: "h", m: "min", s: "s", gap: " ", joiner: " ")
        case .vi: return Units(h: "giờ", m: "phút", s: "giây", gap: " ", joiner: " ")
        case .ru: return Units(h: "ч", m: "мин", s: "с", gap: " ", joiner: " ")
        }
    }

    /// `1 小时 34 分 43 秒` / `1h 34m 43s`; zero units are left out (`1 小时 5 秒`).
    static func duration(_ seconds: Double, language: AppLanguage? = nil) -> String {
        let u = units(language ?? Localizer.shared.language)
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded()) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)\(u.gap)\(u.h)") }
        if m > 0 { parts.append("\(m)\(u.gap)\(u.m)") }
        if s > 0 || parts.isEmpty { parts.append("\(s)\(u.gap)\(u.s)") }
        return parts.joined(separator: u.joiner)
    }

    /// Hours and minutes only once a total reaches an hour (`12 小时 5 分`), for library totals.
    static func roughDuration(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded()) : 0
        guard total >= 3600 else { return duration(seconds) }
        let u = units(Localizer.shared.language)
        let h = total / 3600, m = (total % 3600) / 60
        var parts = ["\(h)\(u.gap)\(u.h)"]
        if m > 0 { parts.append("\(m)\(u.gap)\(u.m)") }
        return parts.joined(separator: u.joiner)
    }

    /// `1:34:43` / `3:27`, used in the import toast.
    static func compactDuration(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded()) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h):\(pad2(m)):\(pad2(s))" }
        return "\(m):\(pad2(s))"
    }

    /// `HH:MM:SS,mmm`
    static func srtTimestamp(_ t: Double) -> String {
        let ms = t.isFinite && t > 0 ? Int((t * 1000).rounded()) : 0
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let milli = ms % 1000
        let milliText = milli < 10 ? "00\(milli)" : (milli < 100 ? "0\(milli)" : "\(milli)")
        return "\(pad2(h)):\(pad2(m)):\(pad2(s)),\(milliText)"
    }

    private static let formatterLock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    /// Chinese keeps the spec's fixed patterns; other languages use their locale's own order.
    private static func formatter(withTime: Bool) -> DateFormatter {
        let lang = Localizer.shared.language
        let key = "\(lang.rawValue)|\(withTime)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        if lang == .zhHans {
            f.locale = Locale(identifier: "zh_Hans_CN")
            f.dateFormat = withTime ? "yyyy年M月d日 ah:mm" : "yyyy年M月d日"
        } else {
            f.locale = lang.locale
            f.setLocalizedDateFormatFromTemplate(withTime ? "yMMMdjmm" : "yMMMd")
        }
        formatters[key] = f
        return f
    }

    /// `2026年10月13日 下午4:00` / `Oct 13, 2026 at 4:00 PM`
    static func createdDate(_ date: Date) -> String { formatter(withTime: true).string(from: date) }

    /// `2026年10月13日` / `Oct 13, 2026`
    static func dateOnly(_ date: Date) -> String { formatter(withTime: false).string(from: date) }

    /// Parses `mm:ss`, `hh:mm:ss`, `[mm:ss]`, optional fractional seconds, or plain seconds.
    static func parseTimestamp(_ raw: String) -> Double? {
        var s = raw.trimmed
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]【】()（） "))
        s = s.replacingOccurrences(of: "：", with: ":")
        if s.isEmpty { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { String($0).trimmed }
        func num(_ p: String) -> Double? { Double(p.replacingOccurrences(of: ",", with: ".")) }
        switch parts.count {
        case 1:
            return num(parts[0]).flatMap { $0 >= 0 ? $0 : nil }
        case 2:
            guard let m = num(parts[0]), let sec = num(parts[1]), m >= 0, sec >= 0 else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = num(parts[0]), let m = num(parts[1]), let sec = num(parts[2]),
                  h >= 0, m >= 0, sec >= 0 else { return nil }
            return h * 3600 + m * 60 + sec
        default:
            return nil
        }
    }
}
