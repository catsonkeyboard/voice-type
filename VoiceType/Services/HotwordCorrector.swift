import Foundation

/// 识别结果后处理热词纠正：对文本按热词字数开滑窗，
/// 窗口拼音与热词拼音编辑距离 ≤ ⌈拼音长度×20%⌉（至少 1）即替换。
/// 仅处理 CJK 字符窗口（拼音方案对英文无意义）。
struct HotwordCorrector {
    private let entries: [(chars: [Character], pinyin: String)]

    init(hotwords: [String]) {
        entries = hotwords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy(Self.isCJK) }
            .map { (Array($0), Self.pinyin(of: $0)) }
            .filter { !$0.1.isEmpty }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
    }

    func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        var chars = Array(text)
        for (target, targetPinyin) in entries {
            let n = target.count
            guard chars.count >= n else { continue }
            let maxDistance = max(1, Int((Double(targetPinyin.count) * 0.2).rounded(.up)))
            var i = 0
            while i + n <= chars.count {
                let window = Array(chars[i..<(i + n)])
                if window == target {
                    i += n
                    continue
                }
                guard window.allSatisfy(Self.isCJK) else {
                    i += 1
                    continue
                }
                let windowPinyin = Self.pinyin(of: String(window))
                if Self.levenshtein(targetPinyin, windowPinyin) <= maxDistance {
                    chars.replaceSubrange(i..<(i + n), with: target)
                    i += n
                } else {
                    i += 1
                }
            }
        }
        return String(chars)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
