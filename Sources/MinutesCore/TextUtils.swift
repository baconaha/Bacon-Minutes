import Foundation

extension Character {
    /// Han, kana, hangul, CJK punctuation and full-width forms.
    var isCJKLike: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x2FDF,   // radicals
             0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x30FF,   // hiragana, katakana
             0x3100...0x31FF,   // bopomofo, kana ext
             0x3400...0x4DBF,   // ext A
             0x4E00...0x9FFF,   // unified ideographs
             0xAC00...0xD7AF,   // hangul syllables
             0xF900...0xFAFF,   // compatibility ideographs
             0xFE30...0xFE4F,   // compatibility forms
             0xFF00...0xFFEF,   // half/full width forms
             0x20000...0x2FA1F: // ext B and later
            return true
        default:
            return false
        }
    }

    /// Sentence or clause punctuation, ASCII or CJK.
    var isPunctuationLike: Bool {
        if isPunctuation { return true }
        return "…~～、·".contains(self)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Joins two fragments: CJK on either side joins directly, otherwise with a space.
    func joinedFragment(_ next: String) -> String {
        if isEmpty { return next }
        if next.isEmpty { return self }
        if let l = last, let f = next.first, l.isCJKLike || f.isCJKLike {
            return self + next
        }
        return self + " " + next
    }
}

/// Width- and case-insensitive matching on UTF-16 code units, so match offsets map 1:1 onto NSString ranges.
enum TextFold {
    @inline(__always)
    static func foldUnit(_ unit: UInt16) -> UInt16 {
        var v = unit
        if v >= 0xFF01 && v <= 0xFF5E {
            v -= 0xFEE0          // full-width ASCII → ASCII
        } else if v == 0x3000 {
            v = 0x20             // ideographic space
        }
        if v >= 0x41 && v <= 0x5A {
            v += 0x20            // A-Z
        } else if v >= 0xC0 && v <= 0xDE && v != 0xD7 {
            v += 0x20            // Latin-1 capitals
        }
        return v
    }

    static func fold(_ s: String) -> [UInt16] {
        var out = [UInt16]()
        out.reserveCapacity(s.utf16.count)
        for u in s.utf16 { out.append(foldUnit(u)) }
        return out
    }

    /// Start offsets of non-overlapping occurrences of `needle` in `haystack`.
    static func occurrences(of needle: [UInt16], in haystack: [UInt16]) -> [Int] {
        let n = needle.count, h = haystack.count
        guard n > 0, h >= n else { return [] }
        var result: [Int] = []
        let first = needle[0]
        var i = 0
        let last = h - n
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < n && haystack[i + j] == needle[j] { j += 1 }
                if j == n {
                    result.append(i)
                    i += n
                    continue
                }
            }
            i += 1
        }
        return result
    }

    static func contains(_ haystack: [UInt16], _ needle: String) -> Bool {
        !occurrences(of: fold(needle), in: haystack).isEmpty
    }
}

/// Small helpers around NSRegularExpression that behave the same on macOS and Linux.
struct RegexPattern {
    let ns: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Patterns are compile-time constants; a failure here is a programming error.
        ns = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Capture groups of the first match (index 0 = whole match). Missing groups are nil.
    func firstMatch(in s: String) -> [String?]? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = ns.firstMatch(in: s, options: [], range: range) else { return nil }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location == NSNotFound {
                groups.append(nil)
            } else if let sr = Range(r, in: s) {
                groups.append(String(s[sr]))
            } else {
                groups.append(nil)
            }
        }
        return groups
    }

    /// Length (in Characters) of the whole first match, which must start at the beginning of `s`.
    func prefixMatchEnd(in s: String) -> String.Index? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = ns.firstMatch(in: s, options: [.anchored], range: range),
              let r = Range(m.range, in: s) else { return nil }
        return r.upperBound
    }

    func replacing(in s: String, with template: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return ns.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
