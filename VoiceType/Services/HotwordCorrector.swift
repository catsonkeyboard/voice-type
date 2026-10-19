import Foundation

/// 识别结果后处理热词纠正。
///
/// 条目三态（v7）：
/// - 纯 CJK：文本 CJK 滑窗按拼音编辑距离 ≤ ⌈拼音长度×20%⌉ 纠正（v1 行为不变）
/// - 含拉丁：拉丁词段归一化匹配（含精确匹配→规范大小写归位）；长度 <6 仅精确匹配
/// - 混合（拉丁+CJK，如「Vue 组件」）：拉丁段与 CJK 段分别按上述规则组合匹配
/// - 别名（`目标|别名`）：别名按上述规则匹配，命中后整段替换为目标
struct HotwordCorrector {
    private indirect enum Entry {
        /// 纯中文目标（v1 行为不变）
        case cjk(target: [Character], pinyin: String)
        /// 纯拉丁目标（可含 - . / 分隔符）；fuzzy=false（归一化长度 <6）时仅精确匹配
        case latin(target: String, normalized: String, fuzzy: Bool)
        /// 混合目标：单次拉丁↔CJK 切换，如「Vue 组件」/「组件 Vue」
        case mixed(
            target: String, latinNorm: String, latinFuzzy: Bool,
            cjk: [Character], cjkPinyin: String, latinFirst: Bool)
        /// 「目标|别名」：alias 命中后替换为 target
        case alias(target: String, alias: Entry)
    }

    private let entries: [Entry]

    init(hotwords: [String]) {
        entries = hotwords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap(Self.parse)
    }

    private static func parse(_ raw: String) -> Entry? {
        // 别名语法：仅按第一个「|」分割，目标与别名都非空才有效；别名不可级联
        if let pipe = raw.firstIndex(of: "|") {
            let target = String(raw[..<pipe]).trimmingCharacters(in: .whitespaces)
            let aliasRaw = String(raw[raw.index(after: pipe)...])
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !aliasRaw.isEmpty,
                let aliasEntry = parse(aliasRaw)
            else { return nil }
            if case .alias = aliasEntry { return nil }  // 不支持级联别名
            return .alias(target: target, alias: aliasEntry)
        }
        let hasASCII = raw.contains { $0.isASCII && $0.isLetter }
        let hasCJK = raw.contains { Self.isCJK($0) }
        if hasASCII && hasCJK {
            return parseMixed(raw)
        }
        if hasASCII {
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return nil }
            return .latin(
                target: raw, normalized: normalized, fuzzy: normalized.count >= 6)
        }
        if raw.allSatisfy(isCJK) {
            let py = pinyin(of: raw)
            guard !py.isEmpty else { return nil }
            return .cjk(target: Array(raw), pinyin: py)
        }
        return nil
    }

    /// 混合条目：只支持单次拉丁↔CJK 切换（「Vue 组件」或「组件 Vue」），
    /// 多段切换（如「Vue 的组件库」）返回 nil（用户应拆成多条或用别名）
    private static func parseMixed(_ raw: String) -> Entry? {
        var parts: [(isLatin: Bool, text: String)] = []
        for c in raw {
            let latin = c.isASCII && c.isLetter
            let isC = Self.isCJK(c)
            guard latin || isC || c.isWhitespace else { return nil }
            if let last = parts.last, last.isLatin == latin {
                parts[parts.count - 1].text.append(c)
            } else {
                parts.append((latin, String(c)))
            }
        }
        let solid = parts.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard solid.count == 2,
            solid[0].isLatin != solid[1].isLatin
        else { return nil }
        let latinPart = solid.first { $0.isLatin }!.text.trimmingCharacters(in: .whitespaces)
        let cjkPart = solid.first { !$0.isLatin }!.text.trimmingCharacters(in: .whitespaces)
        guard cjkPart.allSatisfy(isCJK) else { return nil }
        let latinNorm = normalize(latinPart)
        let cjkPy = pinyin(of: cjkPart)
        guard !latinNorm.isEmpty, !cjkPy.isEmpty else { return nil }
        return .mixed(
            target: raw, latinNorm: latinNorm, latinFuzzy: latinNorm.count >= 6,
            cjk: Array(cjkPart), cjkPinyin: cjkPy, latinFirst: solid[0].isLatin)
    }

    /// 拉丁归一化：小写 + 去首尾非字母数字
    private static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        let head = lower.drop(while: { !($0.isLetter || $0.isNumber) })
        let trimmedTail = head.reversed().drop(while: { !($0.isLetter || $0.isNumber) })
        return String(trimmedTail.reversed())
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    /// 拉丁词段字符：ASCII 字母/数字 + 内部分隔符（- . /）。
    /// 注意不能用 Character.isLetter——CJK 也是 letter，会把中文吞进拉丁段
    private static func isLatinWordChar(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (scalar.isASCII && (c.isLetter || c.isNumber))
            || c == "-" || c == "." || c == "/"
    }

    static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 纠正主流程

    func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            var consumed = false
            for entry in entries {
                if let width = Self.match(entry, in: chars, at: i) {
                    var replacement = Array(Self.target(of: entry))
                    // CJK 窗口被替换为含拉丁的文本时，两侧按需补空格
                    //（「部署到库伯内提斯」→「部署到 Kubernetes」而非「部署到Kubernetes」）
                    let windowIsCJK = chars[i..<(i + width)].allSatisfy { Self.isCJK($0) }
                    let replHasLatin = replacement.contains {
                        $0.isASCII && $0.isLetter
                    }
                    if windowIsCJK && replHasLatin {
                        if i > 0, Self.isCJK(chars[i - 1]) || chars[i - 1].isNumber {
                            replacement.insert(" ", at: 0)
                        }
                        let endIdx = i + width
                        if endIdx < chars.count,
                            Self.isCJK(chars[endIdx]) || chars[endIdx].isNumber
                        {
                            replacement.append(" ")
                        }
                    }
                    chars.replaceSubrange(i..<(i + width), with: replacement)
                    i += replacement.count
                    consumed = true
                    break
                }
            }
            if !consumed { i += 1 }
        }
        return String(chars)
    }

    /// 命中返回被替换窗口的宽度；未命中返回 nil。
    /// replaceExact=false（顶层匹配）时精确等于目标不替换（原文已正确）；
    /// 别名场景恒为 true——别名精确命中正是要替换的场景。
    private static func match(
        _ entry: Entry, in chars: [Character], at i: Int, replaceExact: Bool = false
    ) -> Int? {
        switch entry {
        case .cjk(let target, let targetPinyin):
            let n = target.count
            guard i + n <= chars.count else { return nil }
            let window = Array(chars[i..<(i + n)])
            if window == target {
                return replaceExact ? n : nil
            }
            guard window.allSatisfy(isCJK) else { return nil }
            let maxDistance = max(1, Int((Double(targetPinyin.count) * 0.2).rounded(.up)))
            let windowPinyin = pinyin(of: String(window))
            return levenshtein(targetPinyin, windowPinyin) <= maxDistance ? n : nil

        case .latin(let target, let normalized, let fuzzy):
            guard let width = matchLatinWord(normalized, fuzzy: fuzzy, in: chars, at: i)
            else { return nil }
            _ = target
            return width

        case .mixed(_, let latinNorm, let latinFuzzy, let cjk, let cjkPinyin, let latinFirst):
            // 依次匹配两段（中间允许空白）；任一段失败即整体不命中
            if latinFirst {
                guard let w1 = matchLatinWord(latinNorm, fuzzy: latinFuzzy, in: chars, at: i),
                    let after = skipSpaces(chars, i + w1),
                    let w2 = matchCjkWindow(cjk, cjkPinyin, in: chars, at: after)
                else { return nil }
                return after + w2 - i
            } else {
                guard let w1 = matchCjkWindow(cjk, cjkPinyin, in: chars, at: i),
                    let after = skipSpaces(chars, i + w1),
                    let w2 = matchLatinWord(latinNorm, fuzzy: latinFuzzy, in: chars, at: after)
                else { return nil }
                return after + w2 - i
            }

        case .alias(_, let alias):
            return match(alias, in: chars, at: i, replaceExact: true)
        }
    }

    private static func target(of entry: Entry) -> String {
        switch entry {
        case .cjk(let target, _): return String(target)
        case .latin(let target, _, _): return target
        case .mixed(let target, _, _, _, _, _): return target
        case .alias(let target, _): return target
        }
    }

    /// 拉丁词段匹配：返回命中宽度。
    /// 误替换防护：距离 >0 时拒绝严格前缀关系——「graph」是「graphql」的前缀，
    /// 正是 ASR 把一个词拆成两半（"graph ql"）的特征，这种情况不该替换。
    private static func matchLatinWord(
        _ normalized: String, fuzzy: Bool, in chars: [Character], at i: Int
    ) -> Int? {
        guard let (segment, width) = latinSegment(in: chars, at: i) else { return nil }
        let segNorm = normalize(String(segment))
        guard !segNorm.isEmpty else { return nil }
        if segNorm == normalized { return width }
        guard fuzzy else { return nil }
        let maxDistance = max(1, Int((Double(normalized.count) * 0.2).rounded(.up)))
        guard levenshtein(normalized, segNorm) <= maxDistance else { return nil }
        if normalized.hasPrefix(segNorm) || segNorm.hasPrefix(normalized) { return nil }
        return width
    }

    /// CJK 滑窗拼音匹配（混合条目的中文半边）：返回命中宽度
    private static func matchCjkWindow(
        _ target: [Character], _ targetPinyin: String, in chars: [Character], at i: Int
    ) -> Int? {
        let n = target.count
        guard i + n <= chars.count else { return nil }
        let window = Array(chars[i..<(i + n)])
        guard window.allSatisfy(isCJK) else { return nil }
        let maxDistance = max(1, Int((Double(targetPinyin.count) * 0.2).rounded(.up)))
        let windowPinyin = pinyin(of: String(window))
        return levenshtein(targetPinyin, windowPinyin) <= maxDistance ? n : nil
    }

    private static func skipSpaces(_ chars: [Character], _ from: Int) -> Int? {
        guard from <= chars.count else { return nil }
        var j = from
        while j < chars.count, chars[j] == " " { j += 1 }
        return j
    }

    /// 游标 i 必须落在 ASCII 字母/数字上；向右扩展词字符到段尾；
    /// 剔除尾随分隔符（如句尾 "kubernetes." 的点不属于词）
    private static func latinSegment(in chars: [Character], at i: Int) -> ([Character], Int)? {
        guard i < chars.count,
            let s = chars[i].unicodeScalars.first, s.isASCII,
            chars[i].isLetter || chars[i].isNumber
        else { return nil }
        var j = i + 1
        while j < chars.count, isLatinWordChar(chars[j]) { j += 1 }
        var end = j
        while end > i + 1,
            chars[end - 1] == "-" || chars[end - 1] == "." || chars[end - 1] == "/"
        {
            end -= 1
        }
        return (Array(chars[i..<end]), end - i)
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
