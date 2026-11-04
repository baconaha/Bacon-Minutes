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

    /// `1 小时 34 分 43 秒`; zero units are left out (`1 小时 5 秒`).
    static func durationCN(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded()) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 { parts.append("\(m) 分") }
        if s > 0 || parts.isEmpty { parts.append("\(s) 秒") }
        return parts.joined(separator: " ")
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

    private static let createdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月d日 ah:mm"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    /// `2026年10月13日 下午4:00`
    static func createdDate(_ date: Date) -> String { createdFormatter.string(from: date) }

    /// `2026年10月13日`
    static func dateOnly(_ date: Date) -> String { dateOnlyFormatter.string(from: date) }

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
