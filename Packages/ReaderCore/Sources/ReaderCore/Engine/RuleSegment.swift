//
//  RuleSegment.swift
//  ReaderCore
//
//  规则串分段与模式判定。这是整个引擎最容易被误实现的一层：
//  架构文档二·二明确列出四条「不会报错、只会返回空串」的静默失败坑，
//  这里逐条对齐，并在注释里标出对应的上游语义。
//
//  一、整串分段
//    正则 `<js>([\w\W]*?)</js>|@js:([\w\W]*)`
//    - `<js>...</js>` 非贪婪，可跨行，可以出现多次
//    - `@js:` 贪婪到底 —— 一旦出现，后面所有内容都属于 JS 段，不再回到普通段
//    - `@webjs:([\w\W]{5,})` 单独切出 WebJs 段（本版不支持，用于静态标记）
//
//  二、单段 mode 前缀判定顺序（顺序本身会影响结果）
//    @CSS: → Default（去掉前缀）
//    @@    → Default 并去掉两个字符
//    @XPath: → XPath
//    @Json:  → Json
//    $. / $[ / 本身是 JSON → Json
//    / 开头 → XPath     ← 必须放在 @CSS/@@/@XPath/@Json 之后，否则被前面的分支吃掉
//
//  三、`{{}}` 内嵌优先
//    {{...}} 的内容若以 @ / $. / $[ / // 开头，视为「嵌套规则」重新求值，
//    而不是 JS 表达式。漏掉这条会让一批书源取不到值但不报错。
//
//  四、`##` 位置影响 mode
//    若第一个求值标记（{{ / @get / @js）出现在第一个 `##` 之后，则不切到 Regex 模式。
//

import Foundation

// MARK: - 段类型

public enum RuleSegmentKind: Sendable, Equatable {
    /// 普通选择器段（Default / XPath / Json / Regex 由 mode 决定）
    case plain
    /// `<js>...</js>` 段
    case js
    /// `@js:` 段（贪婪到底，理论上只会是最后一段）
    case jsTail
    /// `@webjs:` 段（本版不支持）
    case webJs
}

public enum RuleMode: String, Sendable, Equatable {
    case `default` = "Default"
    case xpath = "XPath"
    case json = "Json"
    case regex = "Regex"
}

public struct RuleSegment: Sendable, Equatable {
    public var kind: RuleSegmentKind
    /// 已剥掉前置模式前缀的原始规则体
    public var rule: String
    /// 本段模式（js / webJs 段这里无意义，保留 default 占位）
    public var mode: RuleMode
    /// `##匹配##替换##` 拆出的替换规则；nil 表示无替换
    public var replacement: ReplacementRule?
    /// `@put:{key:rule}` 求值后写入变量表的项
    public var puts: [PutInstruction]
    /// 本段是否包含 `@get:` / `{{}}` / `$n` 等需回填的标记，用于「##位置影响 mode」判断
    public var hasEvalMarker: Bool

    public init(kind: RuleSegmentKind,
                rule: String,
                mode: RuleMode = .default,
                replacement: ReplacementRule? = nil,
                puts: [PutInstruction] = [],
                hasEvalMarker: Bool = false) {
        self.kind = kind
        self.rule = rule
        self.mode = mode
        self.replacement = replacement
        self.puts = puts
        self.hasEvalMarker = hasEvalMarker
    }
}

/// `##匹配##替换##` 链。第三段存在（哪怕为空字符串后仍有内容）即「只替换首个」。
public struct ReplacementRule: Sendable, Equatable {
    public var pattern: String
    public var replacement: String
    public var replaceFirstOnly: Bool
}

/// `@put:{key:rule}` 一条
public struct PutInstruction: Sendable, Equatable {
    public var key: String
    public var rule: String
}

// MARK: - 分段器

public enum RuleParser {

    private static let jsTagRegex = try! NSRegularExpression(
        pattern: "<js>([\\w\\W]*?)</js>", options: []
    )
    /// `@js:` 贪婪到底：`@js:` 之后的所有字符都归 JS。
    private static let jsAtRegex = try! NSRegularExpression(
        pattern: "@js:([\\w\\W]*)", options: []
    )
    private static let webJsRegex = try! NSRegularExpression(
        pattern: "@webjs:([\\w\\W]{5,})", options: []
    )

    /// 整串分段。返回按出现顺序排列的段。
    public static func parse(_ rawRule: String) -> [RuleSegment] {
        let rule = rawRule
        guard !rule.isEmpty else { return [] }

        // 先扫出所有「特殊段」的区间：<js>…</js>、@js:…（到末尾）、@webjs:…（到末尾）
        struct Span { var range: Range<String.Index>; var kind: RuleSegmentKind }
        var spans: [Span] = []

        for m in jsTagRegex.matches(in: rule, range: NSRange(rule.startIndex..., in: rule)) {
            guard let r = Range(m.range, in: rule) else { continue }
            spans.append(Span(range: r, kind: .js))
        }

        // @webjs: 与 @js: 都是「贪婪到末尾」，谁在前面谁生效
        let webMatch = webJsRegex.firstMatch(in: rule, range: NSRange(rule.startIndex..., in: rule))
        let jsAtMatch = jsAtRegex.firstMatch(in: rule, range: NSRange(rule.startIndex..., in: rule))
        if let w = webMatch, let r = Range(w.range, in: rule) {
            spans.append(Span(range: r, kind: .webJs))
        } else if let j = jsAtMatch, let r = Range(j.range, in: rule) {
            spans.append(Span(range: r, kind: .jsTail))
        }

        spans.sort { $0.range.lowerBound < $1.range.lowerBound }

        // 剔除被前面贪婪段覆盖的后续段
        var deduped: [Span] = []
        for s in spans {
            if let last = deduped.last, s.range.lowerBound < last.range.upperBound
                || (last.kind == .jsTail || last.kind == .webJs) {
                continue
            }
            deduped.append(s)
        }

        var segments: [RuleSegment] = []
        var cursor = rule.startIndex
        for span in deduped {
            if cursor < span.range.lowerBound {
                let chunk = String(rule[cursor..<span.range.lowerBound])
                if !chunk.isEmpty {
                    segments.append(makePlainSegment(chunk))
                }
            }
            let body = String(rule[span.range])
            switch span.kind {
            case .js:
                // 剥掉 <js> 与 </js>
                let inner = body
                    .replacingOccurrences(of: "<js>", with: "")
                    .replacingOccurrences(of: "</js>", with: "")
                segments.append(RuleSegment(kind: .js, rule: inner))
            case .jsTail:
                let inner = body.hasPrefix("@js:") ? String(body.dropFirst(4)) : body
                segments.append(RuleSegment(kind: .jsTail, rule: inner))
            case .webJs:
                let inner = body.hasPrefix("@webjs:") ? String(body.dropFirst(7)) : body
                segments.append(RuleSegment(kind: .webJs, rule: inner))
            case .plain:
                break
            }
            cursor = span.range.upperBound
        }
        if cursor < rule.endIndex {
            let chunk = String(rule[cursor...])
            if !chunk.isEmpty {
                segments.append(makePlainSegment(chunk))
            }
        }
        return segments
    }

    /// 判断整条规则是否含 JS（导入时静态扫描用）。
    /// 注意：`@js:` 与 `<js>` 与 `@webjs:` 都算。
    public static func containsJS(_ rule: String?) -> Bool {
        guard let rule, !rule.isEmpty else { return false }
        return rule.contains("@js:") || rule.contains("<js>") || rule.contains("</js>")
            || rule.contains("@webjs:")
    }

    /// 段内模式判定 + 替换链拆解 + @put 抽取。
    static func makePlainSegment(_ raw: String) -> RuleSegment {
        var text = raw
        var mode: RuleMode = .default

        // ① 模式前缀（顺序敏感）
        // 大小写不敏感：书源里 `@css:` / `@CSS:` / `@Css:` 都出现过
        let lower = text.lowercased()
        if lower.hasPrefix("@css:") {
            mode = .default
            text = String(text.dropFirst(5))
        } else if text.hasPrefix("@@") {
            mode = .default
            text = String(text.dropFirst(2))
        } else if lower.hasPrefix("@xpath:") {
            mode = .xpath
            text = String(text.dropFirst(7))
        } else if lower.hasPrefix("@json:") {
            mode = .json
            text = String(text.dropFirst(6))
        } else if text.hasPrefix("$.") || text.hasPrefix("$[") {
            mode = .json
        } else if looksLikeJSON(text) {
            mode = .json
        } else if text.hasPrefix("/") {
            mode = .xpath
        }

        // ② 抽 @put:{key:rule}（可多条）
        var puts: [PutInstruction] = []
        var working = text
        while let extracted = extractPut(&working) {
            puts.append(extracted)
        }

        // ③ hasEvalMarker：{{ / @get: / $n
        let hasMarker = working.contains("{{") || working.contains("@get:")
            || RegexHelpers.containsGroupRef(working)

        // ④ ## 替换链：只在「第一个求值标记之后」出现时才切 Regex
        //    （架构文档：## 出现在第一个求值标记之前时，该段不切换为 Regex 模式）
        var replacement: ReplacementRule?
        if working.contains("##") {
            let firstMarkerIndex = firstEvalMarkerIndex(working)
            let firstHashIndex = working.range(of: "##")?.lowerBound
            let shouldTreatAsRegex: Bool = {
                if mode != .default { return true }  // 已显式指定模式的段不受此限
                guard let h = firstHashIndex else { return false }
                guard let m = firstMarkerIndex else { return true }
                return m < h
            }()
            if shouldTreatAsRegex {
                replacement = splitReplacementChain(&working)
            }
        }

        return RuleSegment(kind: .plain,
                           rule: working,
                           mode: mode,
                           replacement: replacement,
                           puts: puts,
                           hasEvalMarker: hasMarker)
    }

    /// 抽取一个 `@put:{...}`，把剩下的写回 text。
    private static func extractPut(_ text: inout String) -> PutInstruction? {
        guard let start = text.range(of: "@put:{") else { return nil }
        var i = start.upperBound       // 指向 { 之后
        var depth = 1
        var body = ""
        var closed = false
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { closed = true; break }
            }
            body.append(c)
            i = text.index(after: i)
        }
        guard closed else { return nil }
        // body 形如 `key:rule`
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let rule = String(body[body.index(after: colon)...])
        var end = text.index(after: i)
        if end < text.endIndex, text[end] == "}" { end = text.index(after: end) }
        // @put:{...} 后面可能还跟着一个多余的 }
        text.removeSubrange(start.lowerBound..<end)
        guard !key.isEmpty, !rule.isEmpty else { return nil }
        return PutInstruction(key: key, rule: rule)
    }

    /// 拆 `匹配##替换##` 链。第三段是否存在决定「只替换首个」。
    static func splitReplacementChain(_ text: inout String) -> ReplacementRule? {
        // 判定必须看「尾随的 ##」，不能用 split 段数：
        //   `div@text##a##b`    → 匹配 a、替换 b，无尾随 ## → 全部替换
        //   `div@text##a##b##`  → 有尾随 ## → 只替换首个
        let hasTrailingMarker = text.hasSuffix("##")
        var body = text
        if hasTrailingMarker { body = String(body.dropLast(2)) }
        let parts = body.components(separatedBy: "##")
        guard parts.count >= 2 else { return nil }
        let selector = parts[0]
        let pattern = parts[1]
        let replacement = parts.count > 2 ? parts[2] : ""
        let firstOnly = hasTrailingMarker
        text = selector
        guard !pattern.isEmpty else { return nil }
        return ReplacementRule(pattern: pattern, replacement: replacement, replaceFirstOnly: firstOnly)
    }

    private static func firstEvalMarkerIndex(_ text: String) -> String.Index? {
        var best: String.Index?
        for token in ["{{", "@get:"] {
            if let r = text.range(of: token) {
                if best == nil || r.lowerBound < best! { best = r.lowerBound }
            }
        }
        if let r = RegexHelpers.firstGroupRefRange(text) {
            if best == nil || r.lowerBound < best! { best = r.lowerBound }
        }
        return best
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }
}

// MARK: - 小工具

enum RegexHelpers {
    /// 组引用 `$1`..`$99`（排除 `$$` 这种转义与 `${...}`）
    static func firstGroupRefRange(_ text: String) -> Range<String.Index>? {
        guard text.contains("$") else { return nil }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$" {
                let next = text.index(after: i)
                guard next < text.endIndex else { break }
                if text[next].isNumber {
                    var j = next
                    while j < text.endIndex, text[j].isNumber { j = text.index(after: j) }
                    return i..<j
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func containsGroupRef(_ text: String) -> Bool {
        firstGroupRefRange(text) != nil
    }
}
